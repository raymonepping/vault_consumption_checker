# Vault client diff report

## Overall

- old start_time: `2023-06-01T00:00:00Z`
- new start_time: `2024-06-01T00:00:00Z`
- old clients: `573`
- new clients: `603`
- delta clients: `30`

## Top increases

| namespace | old | new | delta |
|---|---:|---:|---:|
| okta/ | 0 | 28 | +28 |
| root | 60 | 74 | +14 |
| prod/azptest24/ | 7 | 15 | +8 |
| prod/gcppt25/ | 0 | 8 | +8 |
| dr/gcpptest2/ | 0 | 7 | +7 |
| sand/tameed/ | 0 | 7 | +7 |
| sand/waas/ | 0 | 7 | +7 |
| dr/sdb/ | 1 | 6 | +5 |
| dr/drt287/ | 5 | 7 | +2 |
| sand/sdb/ | 4 | 6 | +2 |
| deleted namespace "EqZ38" | 3 | 4 | +1 |
| dr/atlas/ | 0 | 1 | +1 |
| dr/ta3meed/ | 0 | 1 | +1 |
| prod/cd/ | 11 | 12 | +1 |
| prod/drt287/ | 3 | 4 | +1 |

## Top decreases

| namespace | old | new | delta |
|---|---:|---:|---:|
| sand/zurich/ | 17 | 8 | -9 |
| sand/platform/ | 60 | 51 | -9 |
| deleted namespace "hy090" | 8 | 0 | -8 |
| sand/osb/ | 4 | 0 | -4 |
| sand/adq/ | 4 | 0 | -4 |
| deleted namespace "uQSXH" | 4 | 0 | -4 |
| deleted namespace "fhHaj" | 4 | 0 | -4 |
| deleted namespace "6PPAx" | 4 | 0 | -4 |
| deleted namespace "8Egsn" | 3 | 0 | -3 |
| prod/azfra1/ | 16 | 14 | -2 |
| dr/platform/ | 20 | 18 | -2 |
| deleted namespace "YFqMn" | 2 | 0 | -2 |
| sand/jago/ | 10 | 9 | -1 |
| sand/bsf/ | 4 | 3 | -1 |
| sand/azfra1/ | 16 | 15 | -1 |

## Full namespace delta (top 15 by change)

| namespace | old_clients | new_clients | delta_clients | old_mounts | new_mounts | delta_mounts |
|---|---:|---:|---:|---:|---:|---:|
| okta/ | 0 | 28 | 28 | 0 | 1 | 1 |
| root | 60 | 74 | 14 | 4 | 4 | 0 |
| prod/gcppt25/ | 0 | 8 | 8 | 0 | 1 | 1 |
| prod/azptest24/ | 7 | 15 | 8 | 1 | 1 | 0 |
| sand/waas/ | 0 | 7 | 7 | 0 | 1 | 1 |
| sand/tameed/ | 0 | 7 | 7 | 0 | 1 | 1 |
| dr/gcpptest2/ | 0 | 7 | 7 | 0 | 1 | 1 |
| dr/sdb/ | 1 | 6 | 5 | 1 | 1 | 0 |
| sand/sdb/ | 4 | 6 | 2 | 1 | 1 | 0 |
| dr/drt287/ | 5 | 7 | 2 | 1 | 1 | 0 |
| prod/ta3meed/ | 2 | 3 | 1 | 1 | 1 | 0 |
| prod/sdb/ | 3 | 4 | 1 | 1 | 1 | 0 |
| prod/drt287/ | 3 | 4 | 1 | 1 | 1 | 0 |
| prod/cd/ | 11 | 12 | 1 | 1 | 1 | 0 |
| dr/ta3meed/ | 0 | 1 | 1 | 0 | 1 | 1 |

