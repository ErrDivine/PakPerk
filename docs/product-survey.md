# Product questionnaire

The invitation appears after 15 minutes of accumulated foreground use. Time in
the background does not count, and the total survives app restarts. “Remind me
later” schedules another invitation 15 minutes later, shown when the app is in
the foreground. Refusing, accepting, or completing stops automatic invitations.
The You tab always offers **Share your thoughts** to start or resume voluntarily.

There are eight questions: overall experience, finding papers, reading layout,
figures/tables/formulas, translation, notes, navigation, and speed. Grades are
5 = 很好, 4 = 好, 3 = 不错, 2 = 一般, 1 = 差. The feature questions also allow
“Haven’t tried this yet”; these answers are stored as null. Suggestions are optional.
Copy follows the English/Chinese language setting.

Drafts stay in device preferences. Only Submit sends answers to
`POST /v1/product-surveys`; no account, name, email, or device ID is attached.
Failed submissions retain the same response ID for safe retry without duplicate
records. The server validates all eight answers, caps suggestions at 2,000
characters, and rate-limits submissions. Apply migration 0025 when deploying.

Responses live in PostgreSQL's `product_surveys` table. There is no public read
endpoint. With the local Docker stack running, export for the product owner:

```powershell
python scripts/export_product_surveys.py questionnaire-results.csv
```

The export uses UTF-8 with a BOM for Chinese text in Excel, and guards free-text
suggestions against spreadsheet formula execution. Empty rating cells mean
“not tried yet”. An existing output file is never overwritten.
