# OmaTasks components

Task rows, details, composer, pickers, and supporting models adapted from
[crmne/omatasks](https://github.com/crmne/omatasks/tree/7cd8b201ce5e17ea57bcbc12c5d6f8f02b15acc1)
(commit `7cd8b201ce5e17ea57bcbc12c5d6f8f02b15acc1`). Copyright Carmine Paolino;
see [LICENSE](LICENSE).

Local adaptations translate visible strings and dates into French, preserve
inline French/English edit parsing, expose task-row drag hooks and grouped-date
labels, and provide synthetic UI test identifiers. The parent plugin supplies
the service adapter: these components do not store credentials or send HTTP
requests themselves. Tabs, nested task grouping, and drag destinations remain
managed by the parent panel.
