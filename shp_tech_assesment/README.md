# SHP Q4 Quality & Cost Analysis

## Project Overview
A data analysis exercise for a health plan (SHP). Using claims, encounters, care management, utilization management (UM) and operational data for about 1,000 members (Jan 1 to Oct 15, 2025), I answered three Board questions:
1. Who are the highest-risk members?
2. Are the care management programs effective?
3. Where should resources be focused in 2026?

## Key Findings
- The top 10% of members drive 45% of plan-paid cost; inpatient care is about 70% of cost.
- Care management is not reaching the highest-cost members: 37 of the 73 high-risk members have never been enrolled.
- Program effectiveness is unproven: no detectable change in ER visits or admissions, and the sample is too small to be sure.
- 83 inpatient claims ($1.6M, 18% of paid cost) carry routine or minor diagnoses and should be reviewed.
- 21% of prior-authorization requests are denied, and 41% of decided appeals are overturned.

## Tools Used
- SQL
- Microsoft Excel
- Microsoft Word / PDF

## Project Files
| Folder / file | Contents |
|---|---|
| `reports/` | Executive summary, detailed analysis, assumptions & methodology, approach note |
| `visualizations/` | 11 charts (PNG) |
| `scripts/` | SQL queries (`sql_queries.sql`) |
| `outputs/` | Member segmentation, priority outreach list, Excel validation workbook, supporting tables |

The source data files are confidential and are not included.

## Limitations
- The data is a ~1,000-member sample, so read the percentages, not the dollar totals.
- There is no budget, premium or eligibility data, so the "costs above budget" claim could not be tested.
- Care management results rest on only 68 members with enough before-and-after data.

## Conclusion
This project takes raw health plan data through validation, risk definition and program testing to a short, plain-English recommendation for the Board.
