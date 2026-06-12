#!/usr/bin/env python3
"""
Timeline Matcher - Match photos to Google Timeline locations.
Called by the GeotagTimeline Lightroom plugin.

Usage:
    python timeline_matcher.py <input.json> <output.json>

Input JSON format:
    {
        "timeline_path": "path/to/timeline.json",
        "max_hours": 24,
        "time_adjustment_hours": 0,
        "reverse_geocode": true,
        "photos": [
            {"id": "123", "filename": "DSC_001.NEF", "timestamp": 1728732600}
        ]
    }

Output JSON format:
    {
        "results": [
            {
                "id": "123",
                "matched": true,
                "latitude": 40.76,
                "longitude": -73.98,
                "time_diff_hours": 0.3,
                "city": "New York",
                "state": "New York",
                "country": "United States",
                "iso_country_code": "USA"
            }
        ],
        "stats": {"total": 1, "matched": 1, "unmatched": 0, "errors": 0}
    }
"""

import sys
import json
import datetime
import bisect
import time
import urllib.request
import urllib.parse


def parse_timeline(timeline_path):
    """Parse Google Timeline JSON, return sorted list of (timestamp, lat, lon)."""
    with open(timeline_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    locations = []

    if 'semanticSegments' in data:
        for segment in data['semanticSegments']:
            # Movement data
            if 'timelinePath' in segment:
                for point in segment['timelinePath']:
                    time_str = point.get('time')
                    point_str = point.get('point')
                    if time_str and point_str:
                        try:
                            dt = datetime.datetime.fromisoformat(time_str)
                            coords = point_str.replace('\u00b0', '').split(', ')
                            if len(coords) == 2:
                                locations.append(
                                    (dt.timestamp(), float(coords[0]), float(coords[1]))
                                )
                        except (ValueError, IndexError):
                            continue

            # Visit locations
            if 'visit' in segment:
                candidate = segment['visit'].get('topCandidate', {})
                place_loc = candidate.get('placeLocation', {})
                latlng = place_loc.get('latLng')
                start_time = segment.get('startTime')
                if latlng and start_time:
                    try:
                        dt = datetime.datetime.fromisoformat(start_time)
                        coords = latlng.replace('\u00b0', '').split(', ')
                        if len(coords) == 2:
                            locations.append(
                                (dt.timestamp(), float(coords[0]), float(coords[1]))
                            )
                    except (ValueError, IndexError):
                        continue

    elif 'locations' in data:
        for loc in data['locations']:
            if 'latitudeE7' in loc and 'longitudeE7' in loc:
                ts_ms = loc.get('timestampMs')
                if ts_ms:
                    locations.append((
                        int(ts_ms) / 1000.0,
                        loc['latitudeE7'] / 1e7,
                        loc['longitudeE7'] / 1e7,
                    ))

    elif 'timelineObjects' in data:
        for obj in data['timelineObjects']:
            # Position objects
            if 'position' in obj:
                pos = obj['position']
                if 'LatLng' in pos and 'timestamp' in pos:
                    try:
                        dt = datetime.datetime.fromisoformat(pos['timestamp'])
                        coords = pos['LatLng'].replace('\u00b0', '').split(', ')
                        if len(coords) == 2:
                            locations.append(
                                (dt.timestamp(), float(coords[0]), float(coords[1]))
                            )
                    except (ValueError, IndexError):
                        continue

            # Activity segments
            if 'activitySegment' in obj:
                seg = obj['activitySegment']
                loc = seg.get('startLocation', {})
                ts = seg.get('duration', {}).get('startTimestamp')
                if ts and 'latitudeE7' in loc:
                    try:
                        dt = datetime.datetime.fromisoformat(
                            ts.replace('Z', '+00:00')
                        )
                        locations.append((
                            dt.timestamp(),
                            loc['latitudeE7'] / 1e7,
                            loc['longitudeE7'] / 1e7,
                        ))
                    except (ValueError, IndexError):
                        continue

            # Place visits
            elif 'placeVisit' in obj:
                visit = obj['placeVisit']
                loc = visit.get('location', {})
                ts = visit.get('duration', {}).get('startTimestamp')
                if ts and 'latitudeE7' in loc:
                    try:
                        dt = datetime.datetime.fromisoformat(
                            ts.replace('Z', '+00:00')
                        )
                        locations.append((
                            dt.timestamp(),
                            loc['latitudeE7'] / 1e7,
                            loc['longitudeE7'] / 1e7,
                        ))
                    except (ValueError, IndexError):
                        continue

    locations.sort(key=lambda x: x[0])
    return locations


def find_closest(locations, timestamps, photo_ts, max_seconds):
    """Binary search for the closest timeline point to a photo timestamp."""
    idx = bisect.bisect_left(timestamps, photo_ts)
    best_i = None
    best_diff = float('inf')

    for i in (idx - 1, idx):
        if 0 <= i < len(timestamps):
            diff = abs(timestamps[i] - photo_ts)
            if diff < best_diff:
                best_diff = diff
                best_i = i

    if best_i is not None and best_diff <= max_seconds:
        return locations[best_i], best_diff
    return None, None


COUNTRY_CODES = {
    'TR': 'TUR', 'US': 'USA', 'GB': 'GBR', 'DE': 'DEU', 'FR': 'FRA',
    'IT': 'ITA', 'ES': 'ESP', 'GR': 'GRC', 'RU': 'RUS', 'CN': 'CHN',
    'JP': 'JPN', 'CA': 'CAN', 'AU': 'AUS', 'BR': 'BRA', 'IN': 'IND',
    'MX': 'MEX', 'AE': 'ARE', 'SA': 'SAU', 'EG': 'EGY', 'ZA': 'ZAF',
    'NL': 'NLD', 'BE': 'BEL', 'CH': 'CHE', 'AT': 'AUT', 'SE': 'SWE',
    'NO': 'NOR', 'DK': 'DNK', 'FI': 'FIN', 'PL': 'POL', 'CZ': 'CZE',
    'HU': 'HUN', 'RO': 'ROU', 'BG': 'BGR', 'HR': 'HRV', 'SI': 'SVN',
    'SK': 'SVK', 'PT': 'PRT', 'IE': 'IRL', 'IS': 'ISL', 'KR': 'KOR',
    'TH': 'THA', 'VN': 'VNM', 'PH': 'PHL', 'ID': 'IDN', 'MY': 'MYS',
    'SG': 'SGP', 'NZ': 'NZL', 'AR': 'ARG', 'CL': 'CHL', 'CO': 'COL',
    'PE': 'PER', 'UA': 'UKR', 'GE': 'GEO', 'AM': 'ARM', 'AZ': 'AZE',
    'IL': 'ISR', 'JO': 'JOR', 'LB': 'LBN', 'CY': 'CYP', 'MT': 'MLT',
    'LU': 'LUX', 'EE': 'EST', 'LV': 'LVA', 'LT': 'LTU', 'RS': 'SRB',
    'BA': 'BIH', 'ME': 'MNE', 'MK': 'MKD', 'AL': 'ALB',
}


def reverse_geocode(lat, lon):
    """Reverse geocode coordinates using Nominatim (OpenStreetMap)."""
    try:
        params = urllib.parse.urlencode({
            'lat': lat,
            'lon': lon,
            'format': 'json',
            'addressdetails': 1,
            'accept-language': 'en',
        })
        url = f"https://nominatim.openstreetmap.org/reverse?{params}"
        req = urllib.request.Request(url)
        req.add_header('User-Agent', 'GeotagTimeline-LightroomPlugin/1.0')

        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())

        addr = data.get('address', {})
        city = (
            addr.get('city')
            or addr.get('town')
            or addr.get('village')
            or addr.get('municipality')
            or addr.get('county')
            or addr.get('district')
            or ''
        )
        state = (
            addr.get('state')
            or addr.get('province')
            or addr.get('region')
            or ''
        )
        country = addr.get('country', '')
        cc2 = addr.get('country_code', '').upper()
        cc3 = COUNTRY_CODES.get(cc2, cc2)

        return {
            'city': city,
            'state': state,
            'country': country,
            'iso_country_code': cc3,
        }
    except Exception as e:
        return {
            'city': '',
            'state': '',
            'country': '',
            'iso_country_code': '',
            'geocode_error': str(e),
        }


def write_output(output_path, output):
    """Write output JSON, ensuring valid output even on error."""
    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.json> <output.json>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    # Read input
    with open(input_path, 'r', encoding='utf-8') as f:
        params = json.load(f)

    timeline_path = params['timeline_path']
    max_hours = float(params.get('max_hours', 24))
    time_adjustment = float(params.get('time_adjustment_hours', 0))
    do_geocode = params.get('reverse_geocode', True)
    photos = params['photos']

    # Parse timeline
    try:
        locations = parse_timeline(timeline_path)
    except Exception as e:
        write_output(output_path, {
            'error': f'Failed to parse timeline: {e}',
            'results': [],
            'stats': {
                'total': len(photos), 'matched': 0,
                'unmatched': len(photos), 'errors': 1,
            },
        })
        return

    if not locations:
        write_output(output_path, {
            'error': 'No location data found in timeline file',
            'results': [],
            'stats': {
                'total': len(photos), 'matched': 0,
                'unmatched': len(photos), 'errors': 0,
            },
        })
        return

    # Pre-extract timestamps for binary search
    timestamps = [loc[0] for loc in locations]
    max_seconds = max_hours * 3600
    adjustment_seconds = time_adjustment * 3600

    print(f"Loaded {len(locations)} timeline records", file=sys.stderr)
    print(f"Processing {len(photos)} photos...", file=sys.stderr)

    results = []
    stats = {'total': len(photos), 'matched': 0, 'unmatched': 0, 'errors': 0}

    # Cache reverse geocode results by rounded coords
    geocode_cache = {}

    for photo in photos:
        photo_ts = float(photo['timestamp']) + adjustment_seconds

        loc, diff = find_closest(locations, timestamps, photo_ts, max_seconds)

        if loc is None:
            results.append({
                'id': photo['id'],
                'matched': False,
                'reason': f'No location within {max_hours} hours',
            })
            stats['unmatched'] += 1
            continue

        result = {
            'id': photo['id'],
            'matched': True,
            'latitude': loc[1],
            'longitude': loc[2],
            'time_diff_hours': round(diff / 3600, 2),
        }

        if do_geocode:
            # Round to ~11m precision to reuse nearby lookups
            cache_key = (round(loc[1], 4), round(loc[2], 4))
            if cache_key in geocode_cache:
                geo = geocode_cache[cache_key]
            else:
                time.sleep(1.1)  # Nominatim requires max 1 request/second
                geo = reverse_geocode(loc[1], loc[2])
                geocode_cache[cache_key] = geo
            result.update(geo)

        results.append(result)
        stats['matched'] += 1

    print(
        f"Done: {stats['matched']} matched, {stats['unmatched']} unmatched",
        file=sys.stderr,
    )

    write_output(output_path, {'results': results, 'stats': stats})


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        # If we have an output path, write the error there
        if len(sys.argv) >= 3:
            try:
                write_output(sys.argv[2], {
                    'error': f'Unexpected error: {e}',
                    'results': [],
                    'stats': {'total': 0, 'matched': 0, 'unmatched': 0, 'errors': 1},
                })
            except Exception:
                pass
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
