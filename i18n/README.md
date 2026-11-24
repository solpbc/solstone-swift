# App string catalog

English is authored in [catalog/source/en-US.ftl](catalog/source/en-US.ftl). Each message has a translator sidecar in `catalog/meta/`; history keeps retired identities. Legal text stays English until its translation has legal review. Permission wording requires review before translation.

The generation script uses the compiler's Apple target to produce `Localization/Localizable.xcstrings`, typed Swift calls and each bundle's `InfoPlist.xcstrings`. The included `i18n/generated/project.yml` supplies the same metadata as build-time fallbacks. Xcode compiles a copy of the tables into the app, its extensions and the watch app. Existing native lookup keys are generated aliases, with no separate English authoring table.

Foundation chooses the bundle language from system and per-app preferences. The watch uses its own language preference. The app supplies no language picker and does not write `AppleLanguages`. Only `en-US` is declared today. Adding an approved translation means adding its catalog and registry membership, then regenerating; it needs no call-site changes.

The compiler revision and registry digest are in [compiler.json](compiler.json). Build that revision's `tools/i18n` with its locked Cargo dependencies, then regenerate:

```sh
make i18n-generate I18N_COMPILER=/absolute/path/to/i18n-catalog
make i18n-check
```

Normal builds use the committed generated resources. `make ci` checks their byte lock. Do not edit generated resources or the lock by hand.

Composed sentences carry named arguments. Cardinal messages use native plural selection. Source English keeps its existing formatting, including argument bytes; other languages keep the compiler's bidirectional isolation. Existing date and number formatters retain regional settings, with localized prose selected by the bundle.

`PushCatalog/` and `Sources/Push/PushMessages.xcstrings` remain a separate shared contract. The journal's embedded web interface and the vendored Safari web resources own their own copy.

## Draft locales

Draft locales registered in the pinned locale registry (`development` released, `production` withheld; including `es-419`, `de`, `it` and `te`) keep their draft translations in `catalog/translations/<locale>.ftl` (or sharded files under `catalog/translations/<locale>/`), and production builds exclude them. Unapproved legal and statutory messages stay absent from draft translation files and fall back to English in development builds. When editing English prose, run `i18n-catalog lock` to refresh `source-lock.json`, copy each changed `source` hash into its sidecar `source_revision`, and do not pass `--acknowledge <locale>` for any draft locale: leaving prior acknowledgments untouched marks edited draft entries stale until a translator updates them.
