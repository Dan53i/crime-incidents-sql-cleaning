# Data Dictionary

Columns of `crime_incidents_clean` (33 source columns plus a `row_id` key), and the rule applied to each from the raw table `crime_incidents_messy`.

**Common text rule (`fn_clean_text`):** trim whitespace; `''`, `n/a`, `na`, `null` and `-` (any case) become `NULL`.

## Added column

| Column | Type | Description |
|--------|------|-------------|
| `row_id` | bigint (PK) | Identity assigned after loading the raw CSV. Needed because `incident_id` is not guaranteed unique |

## Incident

| Column | Clean type | Rule |
|--------|------------|------|
| `incident_id` | text | Common text rule. Duplicates are reported, not removed |
| `crime_type` | text | Lookup in `crime_type_map` (e.g. `roberry` to `Robbery`, `homocide` to `Homicide`); otherwise `INITCAP` of the trimmed value |
| `district` | text | `nor/north` to North, `sou/south` to South; East, West, Southwest, Southeast, Northwest, Northeast, Central standardized; blanks to `NULL`; others `INITCAP` |
| `city` | text | Common text rule |
| `state` | text | Common text rule |
| `address` | text | Common text rule |
| `latitude` | numeric(9,6) | Numeric between -90 and 90, else `NULL` |
| `longitude` | numeric(9,6) | Numeric between -180 and 180, else `NULL` |
| `incident_datetime` | timestamp | Accepts `YYYY-MM-DD`, `DD-MM-YYYY`, `DD/MM/YYYY`, each optionally with `HH:MI` or `HH:MI:SS`. Impossible dates become `NULL` |

## Officer

| Column | Clean type | Rule |
|--------|------------|------|
| `officer_id` | text | Common text rule |
| `officer_first_name` | text | Common text rule |
| `officer_last_name` | text | Common text rule |
| `badge_number` | text | Common text rule |

## Suspect

| Column | Clean type | Rule |
|--------|------------|------|
| `suspect_id` | text | Common text rule |
| `suspect_first_name` | text | Common text rule |
| `suspect_last_name` | text | Common text rule |
| `suspect_age` | integer | Numeric 0 to 120 (rounded), else `NULL` |
| `suspect_gender` | text | `m/male` to Male, `f/female` to Female, `other` to Other; unknown and blanks to `NULL`; others `INITCAP` |
| `suspect_race` | text | White, Black, Hispanic, Asian standardized; unknown and blanks to `NULL`; others `INITCAP` |

## Victim

| Column | Clean type | Rule |
|--------|------------|------|
| `victim_id` | text | Common text rule |
| `victim_first_name` | text | Common text rule |
| `victim_last_name` | text | Common text rule |
| `victim_age` | integer | Numeric 0 to 120 (rounded), else `NULL` |
| `victim_gender` | text | Same rule as `suspect_gender` |
| `victim_phone` | text | Common text rule (format is not standardized) |

## Case details

| Column | Clean type | Rule |
|--------|------------|------|
| `weapon_used` | text | Common text rule |
| `severity` | text | Common text rule |
| `case_status` | text | Common text rule |
| `resolution` | text | Common text rule |
| `num_arrests` | integer | Whole number 0 or more (`3` and `3.0` accepted; `3.5` and `-1` rejected) |
| `property_loss_usd` | numeric(14,2) | 0 or more, rounded to 2 decimals, else `NULL` |
| `reported_online` | boolean | `true/t/yes/y/1` to TRUE; `false/f/no/n/0` to FALSE; else `NULL` |
| `notes` | text | Common text rule |

## Constraints on `crime_incidents_clean`

| Constraint | Rule |
|------------|------|
| `PRIMARY KEY` | `row_id` |
| `chk_suspect_age`, `chk_victim_age` | 0 to 120 |
| `chk_latitude` | -90 to 90 |
| `chk_longitude` | -180 to 180 |
| `chk_arrests` | 0 or more |
| `chk_loss` | 0 or more |

## Cleaning log (`crime_incidents_cleaning_log`)

| Column | Description |
|--------|-------------|
| `row_id` | Row in the raw and clean tables |
| `incident_id` | Raw incident id |
| `column_name` | Which column's value was rejected |
| `raw_value` | The original text |
| `reason` | Why it was set to `NULL` |
