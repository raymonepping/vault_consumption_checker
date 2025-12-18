# Vault client count report

## Summary

- start_time: `2023-06-01T00:00:00Z`
- namespaces: `79`
- mounts: `153`

## Totals

| Source | clients | entity_clients | non_entity_clients | acme_clients | secret_syncs |
|---|---:|---:|---:|---:|---:|
| Namespaces (computed) | 573 | 573 | 0 | 0 | 0 |
| Mounts (computed) | 577 | 577 | 0 | 0 | 0 |
| Reported (.total) | 573 | 573 | 0 | 0 | 0 |

## Reconciliation (mounts_sum vs namespace_total)

| namespace | namespace_clients | mounts_clients_sum | delta | mounts |
|---|---:|---:|---:|---:|
| root | 60 | 64 | 4 | 4 |

## Reconciliation details

### root (delta=4)

- namespace_clients: `60`
- mounts_clients_sum: `64`

| mount_path | mount_type | clients |
|---|---|---:|
| auth/okta_oidc/ | oidc/ | 53 |
| no mount accessor (pre-1.10 upgrade?) | deleted mount | 9 |
| auth/userpass/ | userpass/ | 1 |
| auth/jwt/ | jwt/ | 1 |
## Top namespaces by clients

| namespace | clients | mounts |
|---|---:|---:|
| prod/platform/ | 70 | 33 |
| sand/platform/ | 60 | 22 |
| root | 60 | 4 |
| dr/platform/ | 20 | 19 |
| sand/zurich/ | 17 | 1 |
| sand/azfra1/ | 16 | 1 |
| prod/azfra1/ | 16 | 1 |
| prod/cd/ | 11 | 1 |
| sand/jago/ | 10 | 1 |
| prod/zurich/ | 8 | 1 |

## Top mounts by clients

| namespace | mount_path | mount_type | clients |
|---|---|---|---:|
| root | auth/okta_oidc/ | oidc/ | 53 |
| sand/zurich/ | auth/kubernetes/ | kubernetes/ | 17 |
| sand/azfra1/ | auth/kubernetes/ | kubernetes/ | 16 |
| prod/azfra1/ | auth/kubernetes/ | kubernetes/ | 16 |
| prod/cd/ | auth/kubernetes/ | kubernetes/ | 11 |
| sand/jago/ | auth/kubernetes/ | kubernetes/ | 10 |
| sand/platform/ | auth/azfra1/ | kubernetes/ | 10 |
| sand/platform/ | auth/zurich/ | kubernetes/ | 10 |
| prod/platform/ | auth/azfra1/ | kubernetes/ | 10 |
| root | no mount accessor (pre-1.10 upgrade?) | deleted mount | 9 |

