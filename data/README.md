# Data folder

Place the input file here:

```
data/crime_incidents_messy.csv
```

Expected: 5,250 data rows and 33 columns, with a header row, UTF-8 encoded. The pipeline stops if the row count differs.

## Privacy note

The file contains fields such as names and phone numbers. By default `.gitignore` **excludes** `data/*.csv` so the data is not pushed to GitHub by accident.

