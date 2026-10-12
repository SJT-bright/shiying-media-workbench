# Contributor guidance

Use the shared worker protocol for both frontends. Keep the parsing submodule pinned. Test with isolated application data and synthetic sessions; never load production credentials into tests. Preserve saved media, invalid libraries and user logins. Unknown statistics remain unknown. Publication must pass `Scripts/audit_release.py --source` and exclude local data, logs, backups and generated resources. Windows native runtime checks and Mac-host previews must be reported separately. Do not automatically install built packages.
