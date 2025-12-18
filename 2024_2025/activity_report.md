# Vault client count report

## Summary

- start_time: `2024-06-01T00:00:00Z`
- namespaces: `72`
- mounts: `138`

## Totals

| Source | clients | entity_clients | non_entity_clients | acme_clients | secret_syncs |
|---|---:|---:|---:|---:|---:|
| Namespaces (computed) | 603 | 603 | 0 | 0 | 0 |
| Mounts (computed) | 612 | 612 | 0 | 0 | 0 |
| Reported (.total) | 603 | 603 | 0 | 0 | 0 |

## Reconciliation (mounts_sum vs namespace_total)

| namespace | namespace_clients | mounts_clients_sum | delta | mounts |
|---|---:|---:|---:|---:|
| root | 74 | 83 | 9 | 4 |

## Reconciliation details

### root (delta=9)

- namespace_clients: `74`
- mounts_clients_sum: `83`

| mount_path | mount_type | clients |
|---|---|---:|
| auth/okta_oidc/ | oidc/ | 67 |
| no mount accessor (pre-1.10 upgrade?) | deleted mount | 14 |
| auth/jwt/ | jwt/ | 1 |
| auth/userpass/ | userpass/ | 1 |

## Top namespaces by clients

| namespace | clients | mounts |
|---|---:|---:|
| root | 74 | 4 |
| prod/platform/ | 70 | 29 |
| sand/platform/ | 51 | 22 |
| okta/ | 28 | 1 |
| dr/platform/ | 18 | 15 |
| prod/azptest24/ | 15 | 1 |
| sand/azfra1/ | 15 | 1 |
| prod/azfra1/ | 14 | 1 |
| prod/cd/ | 12 | 1 |
| sand/jago/ | 9 | 1 |

## Top mounts by clients

| namespace | mount_path | mount_type | clients |
|---|---|---|---:|
| root | auth/okta_oidc/ | oidc/ | 67 |
| okta/ | auth/jwt_v2/ | jwt/ | 28 |
| prod/azptest24/ | auth/kubernetes/ | kubernetes/ | 15 |
| sand/azfra1/ | auth/kubernetes/ | kubernetes/ | 15 |
| prod/azfra1/ | auth/kubernetes/ | kubernetes/ | 14 |
| root | no mount accessor (pre-1.10 upgrade?) | deleted mount | 14 |
| prod/cd/ | auth/kubernetes/ | kubernetes/ | 12 |
| prod/platform/ | auth/azptest24/ | kubernetes/ | 10 |
| sand/jago/ | auth/kubernetes/ | kubernetes/ | 9 |
| sand/platform/ | auth/azfra1/ | kubernetes/ | 9 |

