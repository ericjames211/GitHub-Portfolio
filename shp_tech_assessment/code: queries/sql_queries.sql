-- SHP Q4 Quality & Cost Analysis: all SQL in run order (SQLite). Load the 5 CSVs as TEXT tables raw_claims, raw_encounters, raw_care_mgmt, raw_um, raw_ops first (scripts/sql/run_sql.py does this).

-- ################ 01_prepare_clean.sql ################
-- =====================================================================================
-- 01_prepare_clean.sql  |  Typed, cleaned tables + data-quality checks (SQLite)
-- Input : raw_claims, raw_encounters, raw_care_mgmt, raw_um, raw_ops (all TEXT, loaded by run_sql.py)
-- Output: claims, encounters, care_mgmt, um, ops, params, r_data_quality
-- =====================================================================================

-- Analysis window: the extract covers 1 Jan - 15 Oct 2025 (288 days, ~9.5 months). ASSUMPTION: every member enrolled for the whole window.
DROP TABLE IF EXISTS params;
CREATE TABLE params AS SELECT '2025-01-01' AS start_date, '2025-10-15' AS end_date, 288 AS ndays, 288/30.4 AS months;

-- CLAIMS: cost = plan-paid amount. Condition group derived from the ICD-10 prefix.
DROP TABLE IF EXISTS claims;
CREATE TABLE claims AS
SELECT claim_id, member_id, claim_date, paid_date, claim_type, service_category, diagnosis_code, provider_id, facility_id,
       CAST(charged_amount AS REAL) AS charged_amount, CAST(allowed_amount AS REAL) AS allowed_amount,
       CAST(paid_amount AS REAL) AS paid_amount, CAST(member_responsibility AS REAL) AS member_responsibility,
       claim_status, denial_reason,
       CASE WHEN diagnosis_code LIKE 'E1%'  THEN 'Diabetes'
            WHEN diagnosis_code LIKE 'J45%' THEN 'Asthma'
            WHEN diagnosis_code LIKE 'J44%' THEN 'COPD'
            WHEN diagnosis_code IN ('I10','I11.9','I12.9','I13.0','I13.10') THEN 'Hypertension'
            WHEN diagnosis_code LIKE 'I%'   THEN 'Cardiac'
            ELSE 'Non-specific / acute' END AS cond_group,
       substr(claim_date, 1, 7) AS claim_month
FROM raw_claims;

-- ENCOUNTERS: member_id has an extra '01' suffix (14 chars vs 12 elsewhere) -> integer divide by 100 and re-pad.
DROP TABLE IF EXISTS encounters;
CREATE TABLE encounters AS
SELECT encounter_id,
       'MBR-' || printf('%08d', CAST(substr(member_id, 5) AS INTEGER) / 100) AS member_id,
       encounter_date, COALESCE(encounter_type, 'UNKNOWN') AS encounter_type, provider_id, facility_id, primary_diagnosis,
       chronic_conditions, admission_date, discharge_date, CAST(length_of_stay AS INTEGER) AS length_of_stay,
       CASE WHEN UPPER(readmission_flag) = 'TRUE' THEN 1 ELSE 0 END AS readmission_flag,
       CASE WHEN UPPER(preventive_flag)  = 'TRUE' THEN 1 ELSE 0 END AS preventive_flag,
       CASE WHEN UPPER(ed_flag)          = 'TRUE' THEN 1 ELSE 0 END AS ed_flag
FROM raw_encounters;

DROP TABLE IF EXISTS care_mgmt;
CREATE TABLE care_mgmt AS
SELECT enrollment_id, member_id, program_name, enrollment_date, disenrollment_date, enrollment_status,
       CAST(risk_score AS REAL) AS risk_score, enrollment_reason, care_manager_id,
       CAST(outreach_attempts AS INTEGER) AS outreach_attempts, CAST(successful_contacts AS INTEGER) AS successful_contacts,
       CAST(completed_assessments AS INTEGER) AS completed_assessments,
       CASE WHEN UPPER(care_plan_created) = 'TRUE' THEN 1 ELSE 0 END AS care_plan_created,
       CAST(goals_met AS INTEGER) AS goals_met, CAST(total_goals AS INTEGER) AS total_goals,
       CASE WHEN UPPER(program_completion_flag) = 'TRUE' THEN 1 ELSE 0 END AS program_completion_flag
FROM raw_care_mgmt;

DROP TABLE IF EXISTS um;
CREATE TABLE um AS
SELECT authorization_id, member_id, request_date, decision_date, service_type, procedure_code, diagnosis_code, requesting_provider_id,
       decision, denial_reason, CAST(authorized_units AS INTEGER) AS authorized_units, CAST(requested_units AS INTEGER) AS requested_units,
       urgency, CASE WHEN UPPER(appeal_flag) = 'TRUE' THEN 1 ELSE 0 END AS appeal_flag, appeal_outcome,
       julianday(decision_date) - julianday(request_date) AS tat_days
FROM raw_um;

DROP TABLE IF EXISTS ops;
CREATE TABLE ops AS
SELECT metric_id, metric_date, metric_name, metric_category, CAST(metric_value AS REAL) AS metric_value, CAST(target_value AS REAL) AS target_value,
       unit_of_measure, performance_status, data_source, notes FROM raw_ops;

-- ---------------- DATA QUALITY CHECKS (each row = one issue; the handling is documented in the report) ----------------
DROP TABLE IF EXISTS r_data_quality;
CREATE TABLE r_data_quality AS
SELECT 'encounters' AS area, 'member_id length <> 12 before cleaning (extra 01 suffix)' AS issue, COUNT(*) AS records FROM raw_encounters WHERE length(member_id) <> 12
UNION ALL SELECT 'encounters', 'cleaned member_id has no match in claims', COUNT(*) FROM encounters WHERE member_id NOT IN (SELECT member_id FROM claims)
UNION ALL SELECT 'encounters', 'encounter_type missing', COUNT(*) FROM raw_encounters WHERE encounter_type IS NULL
UNION ALL SELECT 'encounters', 'INPATIENT_ADMIT rows (stays counted from these)', COUNT(*) FROM encounters WHERE encounter_type = 'INPATIENT_ADMIT'
UNION ALL SELECT 'encounters', 'INPATIENT_DISCHARGE rows (not counted, would double count)', COUNT(*) FROM encounters WHERE encounter_type = 'INPATIENT_DISCHARGE'
UNION ALL SELECT 'encounters', 'readmission_flag = TRUE', COUNT(*) FROM encounters WHERE readmission_flag = 1 AND encounter_type = 'INPATIENT_ADMIT'
UNION ALL SELECT 'encounters', 'admits within 30 days of the same member''s prior discharge (recomputed readmissions)', COUNT(*) FROM (
    SELECT admission_date, LAG(discharge_date) OVER (PARTITION BY member_id ORDER BY admission_date) AS prev_dis
    FROM encounters WHERE encounter_type = 'INPATIENT_ADMIT') WHERE julianday(admission_date) - julianday(prev_dis) BETWEEN 0 AND 30
UNION ALL SELECT 'claims', 'claim_date after end of window', COUNT(*) FROM claims, params WHERE claim_date > end_date
UNION ALL SELECT 'claims', 'paid_date after 2025-10-17', COUNT(*) FROM claims WHERE paid_date > '2025-10-17'
UNION ALL SELECT 'claims', 'DENIED claims with a paid_date (dictionary says null)', COUNT(*) FROM claims WHERE claim_status = 'DENIED' AND paid_date IS NOT NULL
UNION ALL SELECT 'claims', 'DENIED claims with member_responsibility > 0', COUNT(*) FROM claims WHERE claim_status = 'DENIED' AND member_responsibility > 0
UNION ALL SELECT 'claims', 'DENIED claims with paid_amount > 0', COUNT(*) FROM claims WHERE claim_status = 'DENIED' AND paid_amount > 0
UNION ALL SELECT 'claims', 'PENDING claims already carrying paid_amount > 0', COUNT(*) FROM claims WHERE claim_status = 'PENDING' AND paid_amount > 0
UNION ALL SELECT 'claims', 'inpatient claims with routine/symptom dx (Z00.00, J06.9, R51, R50.9, R10.9, K21.9, M54.5)', COUNT(*) FROM claims
       WHERE service_category = 'INPATIENT' AND diagnosis_code IN ('Z00.00','J06.9','R51','R50.9','R10.9','K21.9','M54.5')
UNION ALL SELECT 'care_mgmt', 'risk_score above 10 (documented range 0-10)', COUNT(*) FROM care_mgmt WHERE risk_score > 10
UNION ALL SELECT 'care_mgmt', 'status COMPLETED but program_completion_flag FALSE', COUNT(*) FROM care_mgmt WHERE enrollment_status = 'COMPLETED' AND program_completion_flag = 0
UNION ALL SELECT 'care_mgmt', 'disenrollment_date after end of window', COUNT(*) FROM care_mgmt, params WHERE disenrollment_date > end_date
UNION ALL SELECT 'care_mgmt', 'enrollments starting before 2025 (no pre-period in claims)', COUNT(*) FROM care_mgmt WHERE enrollment_date < '2025-01-01'
UNION ALL SELECT 'care_mgmt', 'enrollments repeating an earlier member+program pair', COUNT(*) FROM (
    SELECT ROW_NUMBER() OVER (PARTITION BY member_id, program_name ORDER BY enrollment_date) AS rn FROM care_mgmt) WHERE rn > 1
UNION ALL SELECT 'ops', 'MLR rows (direction mislabelled in performance_status)', COUNT(*) FROM ops WHERE metric_name = 'Medical Loss Ratio';

-- ################ 02_member_table.sql ################
-- =====================================================================================
-- 02_member_table.sql  |  One row per member (the base table for every later step)
-- Output: members, member_facts
-- =====================================================================================
DROP TABLE IF EXISTS members;
CREATE TABLE members AS
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)       -- member IDs 1..1000 (the extract's universe)
SELECT 'MBR-' || printf('%08d', i) AS member_id FROM n;

DROP TABLE IF EXISTS member_facts;
CREATE TABLE member_facts AS
WITH c AS (   -- claims
    SELECT member_id, COUNT(*) AS claims_n, SUM(paid_amount) AS paid, SUM(allowed_amount) AS allowed,
           SUM(CASE WHEN service_category = 'INPATIENT'    THEN paid_amount END) AS paid_ip,
           SUM(CASE WHEN service_category = 'EMERGENCY'    THEN paid_amount END) AS paid_ed_claims,
           SUM(CASE WHEN service_category = 'OUTPATIENT'   THEN paid_amount END) AS paid_op,
           SUM(CASE WHEN service_category = 'PHARMACY'     THEN paid_amount END) AS paid_rx,
           SUM(CASE WHEN service_category = 'PROFESSIONAL' THEN paid_amount END) AS paid_prof,
           SUM(CASE WHEN claim_status = 'DENIED' THEN 1 ELSE 0 END) AS denied_n
    FROM claims GROUP BY member_id),
e AS (        -- encounters: stays counted from ADMIT rows only
    SELECT member_id,
           SUM(encounter_type = 'INPATIENT_ADMIT') AS ip_admits,
           SUM(encounter_type = 'INPATIENT_ADMIT' AND readmission_flag = 1) AS readmits,
           SUM(encounter_type = 'ED_VISIT') AS ed_visits,
           SUM(encounter_type = 'PREVENTIVE') AS preventive_visits,
           SUM(encounter_type IN ('OFFICE_VISIT','TELEHEALTH')) AS office_tele_visits
    FROM encounters GROUP BY member_id),
cm AS (       -- care management
    SELECT member_id, 1 AS cm_ever, MAX(enrollment_status = 'ACTIVE') AS cm_active, COUNT(DISTINCT program_name) AS cm_programs,
           MAX(risk_score) AS cm_max_risk, MIN(enrollment_date) AS cm_first_enroll
    FROM care_mgmt GROUP BY member_id),
u AS (        -- utilization management
    SELECT member_id, COUNT(*) AS um_requests, SUM(decision = 'DENIED') AS um_denied FROM um GROUP BY member_id),
base AS (
    SELECT m.member_id,
           COALESCE(c.claims_n,0) AS claims_n, COALESCE(c.paid,0) AS paid, COALESCE(c.allowed,0) AS allowed,
           COALESCE(c.paid_ip,0) AS paid_ip, COALESCE(c.paid_ed_claims,0) AS paid_ed_claims, COALESCE(c.paid_op,0) AS paid_op,
           COALESCE(c.paid_rx,0) AS paid_rx, COALESCE(c.paid_prof,0) AS paid_prof, COALESCE(c.denied_n,0) AS denied_n,
           COALESCE(e.ip_admits,0) AS ip_admits, COALESCE(e.readmits,0) AS readmits, COALESCE(e.ed_visits,0) AS ed_visits,
           COALESCE(e.preventive_visits,0) AS preventive_visits, COALESCE(e.office_tele_visits,0) AS office_tele_visits,
           COALESCE(cm.cm_ever,0) AS cm_ever, COALESCE(cm.cm_active,0) AS cm_active, COALESCE(cm.cm_programs,0) AS cm_programs,
           cm.cm_max_risk, cm.cm_first_enroll, COALESCE(u.um_requests,0) AS um_requests, COALESCE(u.um_denied,0) AS um_denied
    FROM members m LEFT JOIN c USING (member_id) LEFT JOIN e USING (member_id) LEFT JOIN cm USING (member_id) LEFT JOIN u USING (member_id))
SELECT b.*,
       -- chronic condition = coded on any claim OR flagged in encounters.chronic_conditions (pipe-delimited)
       CASE WHEN EXISTS (SELECT 1 FROM claims x WHERE x.member_id = b.member_id AND x.cond_group = 'Diabetes')
              OR EXISTS (SELECT 1 FROM encounters x WHERE x.member_id = b.member_id AND x.chronic_conditions LIKE '%DIABETES%') THEN 1 ELSE 0 END AS has_diabetes,
       CASE WHEN EXISTS (SELECT 1 FROM claims x WHERE x.member_id = b.member_id AND x.cond_group = 'Cardiac')
              OR EXISTS (SELECT 1 FROM encounters x WHERE x.member_id = b.member_id AND x.chronic_conditions LIKE '%CARDIAC%') THEN 1 ELSE 0 END AS has_cardiac,
       CASE WHEN EXISTS (SELECT 1 FROM claims x WHERE x.member_id = b.member_id AND x.cond_group = 'Hypertension')
              OR EXISTS (SELECT 1 FROM encounters x WHERE x.member_id = b.member_id AND x.chronic_conditions LIKE '%HYPERTENSION%') THEN 1 ELSE 0 END AS has_hypertension,
       CASE WHEN EXISTS (SELECT 1 FROM claims x WHERE x.member_id = b.member_id AND x.cond_group = 'Asthma')
              OR EXISTS (SELECT 1 FROM encounters x WHERE x.member_id = b.member_id AND x.chronic_conditions LIKE '%ASTHMA%') THEN 1 ELSE 0 END AS has_asthma,
       CASE WHEN EXISTS (SELECT 1 FROM claims x WHERE x.member_id = b.member_id AND x.cond_group = 'COPD')
              OR EXISTS (SELECT 1 FROM encounters x WHERE x.member_id = b.member_id AND x.chronic_conditions LIKE '%COPD%') THEN 1 ELSE 0 END AS has_copd
FROM base b;

ALTER TABLE member_facts ADD COLUMN n_chronic INTEGER;
UPDATE member_facts SET n_chronic = has_diabetes + has_cardiac + has_hypertension + has_asthma + has_copd;

-- Cost concentration: share of total plan-paid cost held by the top 1/5/10/20% of members
DROP TABLE IF EXISTS r_cost_concentration;
CREATE TABLE r_cost_concentration AS
WITH r AS (SELECT paid, ROW_NUMBER() OVER (ORDER BY paid DESC, member_id) AS rk FROM member_facts)
SELECT 'Top 1%' AS grp, ROUND(SUM(CASE WHEN rk <= 10  THEN paid END) / SUM(paid), 4) AS share_of_paid FROM r
UNION ALL SELECT 'Top 5%',  ROUND(SUM(CASE WHEN rk <= 50  THEN paid END) / SUM(paid), 4) FROM r
UNION ALL SELECT 'Top 10%', ROUND(SUM(CASE WHEN rk <= 100 THEN paid END) / SUM(paid), 4) FROM r
UNION ALL SELECT 'Top 20%', ROUND(SUM(CASE WHEN rk <= 200 THEN paid END) / SUM(paid), 4) FROM r;

-- ################ 03_risk_segmentation.sql ################
-- =====================================================================================
-- 03_risk_segmentation.sql  |  Point-score risk tiers, segments, prospective validation, targeting, priority list
-- Score: cost rank (3/2/1) + admissions (3/1) + any readmission (+2) + ED visits (2/1) + chronic conditions (2/1)
-- Tiers: Low 0-1, Moderate 2-3, High 4-5, Very high 6+
-- =====================================================================================
DROP TABLE IF EXISTS member_risk;
CREATE TABLE member_risk AS
WITH ranked AS (   -- cost percentile (ties broken by member_id, matching the Python rank(method='first'))
    SELECT *, ROW_NUMBER() OVER (ORDER BY paid, member_id) / 1000.0 AS cost_rank_pct FROM member_facts),
scored AS (
    SELECT *,
        (CASE WHEN cost_rank_pct > 0.95 THEN 3 WHEN cost_rank_pct > 0.90 THEN 2 WHEN cost_rank_pct > 0.80 THEN 1 ELSE 0 END
       + CASE WHEN ip_admits >= 2 THEN 3 WHEN ip_admits = 1 THEN 1 ELSE 0 END
       + CASE WHEN readmits > 0 THEN 2 ELSE 0 END
       + CASE WHEN ed_visits >= 3 THEN 2 WHEN ed_visits = 2 THEN 1 ELSE 0 END
       + CASE WHEN n_chronic >= 2 THEN 2 WHEN n_chronic = 1 THEN 1 ELSE 0 END) AS risk_points
    FROM ranked)
SELECT *,
       CASE WHEN risk_points <= 1 THEN '1 Low (0-1)' WHEN risk_points <= 3 THEN '2 Moderate (2-3)'
            WHEN risk_points <= 5 THEN '3 High (4-5)' ELSE '4 Very high (6+)' END AS risk_tier,
       CASE WHEN ip_admits >= 1 AND cost_rank_pct > 0.90 THEN 'A. Hospital-driven high cost'
            WHEN ed_visits >= 3 THEN 'B. Frequent ED users'
            WHEN n_chronic >= 2 THEN 'C. Multi-condition chronic'
            WHEN n_chronic = 1  THEN 'D. Single chronic condition'
            WHEN preventive_visits > 0 OR office_tele_visits > 0 THEN 'E. Low-need, engaged in primary care'
            ELSE 'F. Low-need, no primary-care touch' END AS segment
FROM scored;

DROP TABLE IF EXISTS r_tier_profile;
CREATE TABLE r_tier_profile AS
SELECT risk_tier, COUNT(*) AS members, ROUND(COUNT(*) / 10.0, 1) AS pct_members,
       ROUND(100.0 * SUM(paid) / (SELECT SUM(paid) FROM member_risk), 1) AS pct_of_cost,
       ROUND(AVG(paid)) AS paid_per_member, ROUND(100.0 * AVG(ip_admits)) AS admits_per_100, ROUND(100.0 * AVG(ed_visits)) AS ed_per_100,
       ROUND(AVG(n_chronic), 2) AS avg_chronic, ROUND(100.0 * AVG(cm_ever), 1) AS pct_ever_in_cm, SUM(1 - cm_ever) AS never_enrolled
FROM member_risk GROUP BY risk_tier ORDER BY risk_tier;

DROP TABLE IF EXISTS r_segment_profile;
CREATE TABLE r_segment_profile AS
SELECT segment, COUNT(*) AS members, ROUND(100.0 * SUM(paid) / (SELECT SUM(paid) FROM member_risk), 1) AS pct_of_cost, ROUND(AVG(paid)) AS paid_per_member,
       ROUND(100.0 * AVG(ip_admits)) AS admits_per_100, ROUND(100.0 * AVG(ed_visits)) AS ed_per_100, ROUND(AVG(n_chronic), 2) AS avg_chronic,
       ROUND(100.0 * AVG(cm_ever), 1) AS pct_ever_in_cm, ROUND(100.0 * AVG(cm_active), 1) AS pct_active_in_cm
FROM member_risk GROUP BY segment ORDER BY segment;

-- ---------- Prospective validation: score built on Jan-Jun only, outcomes Jul 1 - Oct 15 ----------
DROP TABLE IF EXISTS validation;
CREATE TABLE validation AS
WITH h AS (
    SELECT m.member_id, m.n_chronic,
        COALESCE((SELECT SUM(paid_amount) FROM claims c WHERE c.member_id = m.member_id AND c.claim_date <= '2025-06-30'), 0) AS paid_h1,
        COALESCE((SELECT SUM(paid_amount) FROM claims c WHERE c.member_id = m.member_id AND c.claim_date >= '2025-07-01'), 0) AS paid_h2,
        (SELECT COUNT(*) FROM encounters e WHERE e.member_id = m.member_id AND e.encounter_type = 'INPATIENT_ADMIT' AND e.encounter_date <= '2025-06-30') AS ip_h1,
        (SELECT COUNT(*) FROM encounters e WHERE e.member_id = m.member_id AND e.encounter_type = 'INPATIENT_ADMIT' AND e.encounter_date >= '2025-07-01') AS ip_h2,
        (SELECT COUNT(*) FROM encounters e WHERE e.member_id = m.member_id AND e.encounter_type = 'ED_VISIT' AND e.encounter_date <= '2025-06-30') AS ed_h1,
        (SELECT COUNT(*) FROM encounters e WHERE e.member_id = m.member_id AND e.encounter_type = 'ED_VISIT' AND e.encounter_date >= '2025-07-01') AS ed_h2,
        (SELECT COUNT(*) FROM encounters e WHERE e.member_id = m.member_id AND e.encounter_type = 'INPATIENT_ADMIT' AND e.readmission_flag = 1 AND e.encounter_date <= '2025-06-30') AS rd_h1
    FROM member_facts m),
r AS (SELECT *, ROW_NUMBER() OVER (ORDER BY paid_h1, member_id) / 1000.0 AS rk FROM h)
SELECT *, (CASE WHEN rk > 0.95 THEN 3 WHEN rk > 0.90 THEN 2 WHEN rk > 0.80 THEN 1 ELSE 0 END
         + CASE WHEN ip_h1 >= 2 THEN 3 WHEN ip_h1 = 1 THEN 1 ELSE 0 END + CASE WHEN rd_h1 > 0 THEN 2 ELSE 0 END
         + CASE WHEN ed_h1 >= 3 THEN 2 WHEN ed_h1 = 2 THEN 1 ELSE 0 END
         + CASE WHEN n_chronic >= 2 THEN 2 WHEN n_chronic = 1 THEN 1 ELSE 0 END) AS pts_h1
FROM r;

DROP TABLE IF EXISTS r_validation_by_tier;
CREATE TABLE r_validation_by_tier AS
SELECT CASE WHEN pts_h1 <= 1 THEN '1 Low (0-1)' WHEN pts_h1 <= 3 THEN '2 Moderate (2-3)' WHEN pts_h1 <= 5 THEN '3 High (4-5)' ELSE '4 Very high (6+)' END AS tier_h1,
       COUNT(*) AS members, ROUND(AVG(paid_h2)) AS later_paid_per_member, ROUND(100.0 * AVG(ed_h2)) AS later_ed_per_100, ROUND(100.0 * AVG(ip_h2)) AS later_ip_per_100
FROM validation GROUP BY 1 ORDER BY 1;

-- Pearson correlation of H1 vs H2 cost on ranks (= Spearman, without tie correction); ~0 means cost is not persistent
DROP TABLE IF EXISTS r_validation_corr;
CREATE TABLE r_validation_corr AS
WITH t AS (SELECT RANK() OVER (ORDER BY paid_h1) AS a, RANK() OVER (ORDER BY paid_h2) AS b, RANK() OVER (ORDER BY pts_h1) AS s FROM validation),
     m AS (SELECT AVG(a) AS ma, AVG(b) AS mb, AVG(s) AS ms FROM t)
SELECT ROUND(SUM((a - ma) * (b - mb)) / SQRT(SUM((a - ma) * (a - ma)) * SUM((b - mb) * (b - mb))), 3) AS rank_corr_h1_vs_h2_cost,
       ROUND(SUM((s - ms) * (b - mb)) / SQRT(SUM((s - ms) * (s - ms)) * SUM((b - mb) * (b - mb))), 3) AS rank_corr_score_vs_h2_cost
FROM t, m;

-- ---------- Targeting: who is in care management? ----------
DROP TABLE IF EXISTS r_targeting;
CREATE TABLE r_targeting AS
SELECT 'Top 1%' AS grp, COUNT(*) AS members, ROUND(100.0 * AVG(cm_ever), 1) AS pct_ever_enrolled, ROUND(100.0 * AVG(cm_active), 1) AS pct_active FROM member_risk WHERE cost_rank_pct > 0.99
UNION ALL SELECT 'Top 5%',  COUNT(*), ROUND(100.0 * AVG(cm_ever), 1), ROUND(100.0 * AVG(cm_active), 1) FROM member_risk WHERE cost_rank_pct > 0.95
UNION ALL SELECT 'Top 10%', COUNT(*), ROUND(100.0 * AVG(cm_ever), 1), ROUND(100.0 * AVG(cm_active), 1) FROM member_risk WHERE cost_rank_pct > 0.90
UNION ALL SELECT 'Top 20%', COUNT(*), ROUND(100.0 * AVG(cm_ever), 1), ROUND(100.0 * AVG(cm_active), 1) FROM member_risk WHERE cost_rank_pct > 0.80
UNION ALL SELECT 'Bottom 80%', COUNT(*), ROUND(100.0 * AVG(cm_ever), 1), ROUND(100.0 * AVG(cm_active), 1) FROM member_risk WHERE cost_rank_pct <= 0.80
UNION ALL SELECT 'All members', COUNT(*), ROUND(100.0 * AVG(cm_ever), 1), ROUND(100.0 * AVG(cm_active), 1) FROM member_risk;

-- Rank correlation of the program risk_score with later cost among enrolled members (program score does not track cost)
DROP TABLE IF EXISTS r_cm_risk_score_vs_cost;
CREATE TABLE r_cm_risk_score_vs_cost AS
WITH t AS (SELECT RANK() OVER (ORDER BY cm_max_risk) AS a, RANK() OVER (ORDER BY paid) AS b FROM member_risk WHERE cm_ever = 1), m AS (SELECT AVG(a) ma, AVG(b) mb FROM t)
SELECT ROUND(SUM((a - ma) * (b - mb)) / SQRT(SUM((a - ma) * (a - ma)) * SUM((b - mb) * (b - mb))), 3) AS rank_corr_risk_score_vs_paid FROM t, m;

-- Priority outreach list: High / Very-high members not currently active in care management
DROP TABLE IF EXISTS r_priority_outreach_list;
CREATE TABLE r_priority_outreach_list AS
SELECT member_id, risk_tier, risk_points, ROUND(paid) AS paid, ip_admits, ed_visits, readmits, n_chronic, cm_ever, cm_active, segment,
       CASE WHEN has_cardiac = 1 THEN 'Cardiac Care' WHEN has_diabetes = 1 THEN 'Diabetes Management'
            WHEN has_asthma = 1 OR has_copd = 1 THEN 'Asthma Control' ELSE 'High-Risk Case Management' END AS suggested_program
FROM member_risk WHERE risk_points >= 4 AND cm_active = 0 ORDER BY risk_points DESC, paid DESC;

-- ################ 04_care_mgmt_effectiveness.sql ################
-- =====================================================================================
-- 04_care_mgmt_effectiveness.sql  |  Are care-management programs effective?
--   (a) crude + chronic-only comparison, (b) difference-in-differences, (c) dose-response, (d) program operations
-- NOTE: the Python version draws RANDOM pseudo-enrollment dates for comparison members (200 draws) and bootstraps confidence intervals.
--       SQL has no clean random sampling, so here pseudo-dates are assigned DETERMINISTICALLY (cycled through the treated dates), giving one
--       reproducible draw. Point estimates therefore differ slightly from Python; confidence intervals are Python-only.
-- =====================================================================================

-- (a) Cross-sectional comparison per member-month (window = 9.47 months)
DROP TABLE IF EXISTS r_cm_crude;
CREATE TABLE r_cm_crude AS
SELECT CASE WHEN cm_ever = 1 THEN 'Enrolled (ever)' ELSE 'Not enrolled' END AS grp, COUNT(*) AS members,
       ROUND(SUM(paid) / COUNT(*) / (SELECT months FROM params), 0) AS paid_pmpm,
       ROUND(1000.0 * SUM(ip_admits) / COUNT(*) / (SELECT months FROM params), 1) AS admits_per_1000_mo,
       ROUND(1000.0 * SUM(ed_visits) / COUNT(*) / (SELECT months FROM params), 1) AS ed_per_1000_mo,
       ROUND(AVG(n_chronic), 2) AS avg_chronic, ROUND(100.0 * AVG(n_chronic > 0), 1) AS pct_with_chronic
FROM member_facts GROUP BY cm_ever
UNION ALL
SELECT CASE WHEN cm_ever = 1 THEN 'Enrolled, >=1 chronic' ELSE 'Not enrolled, >=1 chronic' END, COUNT(*),
       ROUND(SUM(paid) / COUNT(*) / (SELECT months FROM params), 0), ROUND(1000.0 * SUM(ip_admits) / COUNT(*) / (SELECT months FROM params), 1),
       ROUND(1000.0 * SUM(ed_visits) / COUNT(*) / (SELECT months FROM params), 1), ROUND(AVG(n_chronic), 2), ROUND(100.0 * AVG(n_chronic > 0), 1)
FROM member_facts WHERE n_chronic > 0 GROUP BY cm_ever;

-- (b) Difference-in-differences ---------------------------------------------------
-- Claim cap = 99th percentile of claim paid_amount (linear interpolation, like pandas quantile)
DROP TABLE IF EXISTS p99;
CREATE TABLE p99 AS
WITH s AS (SELECT paid_amount AS v, ROW_NUMBER() OVER (ORDER BY paid_amount) AS rn FROM claims), n AS (SELECT COUNT(*) AS c FROM claims),
     pos AS (SELECT CAST(0.99 * (c - 1) AS INTEGER) AS lo, 0.99 * (c - 1) - CAST(0.99 * (c - 1) AS INTEGER) AS frac FROM n)
SELECT (SELECT v FROM s WHERE rn = lo + 1) + frac * ((SELECT v FROM s WHERE rn = lo + 2) - (SELECT v FROM s WHERE rn = lo + 1)) AS cap FROM pos;

-- Treated = members whose FIRST-EVER enrollment was 1 Feb - 31 Jul 2025 (>=1 month before, ~2.5+ months after)
DROP TABLE IF EXISTS did_base;
CREATE TABLE did_base AS
WITH t AS (SELECT member_id, MIN(enrollment_date) AS idx_date FROM care_mgmt GROUP BY member_id
           HAVING MIN(enrollment_date) BETWEEN '2025-02-01' AND '2025-07-31'),
     t_ranked AS (SELECT idx_date, ROW_NUMBER() OVER (ORDER BY idx_date, member_id) AS rn FROM t),
     nt AS (SELECT COUNT(*) AS n FROM t),
     c AS (SELECT member_id, ROW_NUMBER() OVER (ORDER BY member_id) - 1 AS k FROM member_facts WHERE cm_ever = 0)
SELECT member_id, 'treated' AS grp, idx_date FROM t
UNION ALL
SELECT c.member_id, 'comparison', (SELECT idx_date FROM t_ranked WHERE rn = (c.k % (SELECT n FROM nt)) + 1) FROM c;

DROP TABLE IF EXISTS did_member;
CREATE TABLE did_member AS
WITH x AS (
  SELECT b.member_id, b.grp, b.idx_date, julianday(b.idx_date) - julianday((SELECT start_date FROM params)) AS t,
    COALESCE((SELECT SUM(MIN(paid_amount, (SELECT cap FROM p99))) FROM claims c WHERE c.member_id = b.member_id AND c.claim_date <  b.idx_date), 0) AS cost_pre,
    COALESCE((SELECT SUM(MIN(paid_amount, (SELECT cap FROM p99))) FROM claims c WHERE c.member_id = b.member_id AND c.claim_date >= b.idx_date), 0) AS cost_post,
    COALESCE((SELECT SUM(paid_amount) FROM claims c WHERE c.member_id = b.member_id AND c.claim_date <  b.idx_date), 0) AS rawcost_pre,
    COALESCE((SELECT SUM(paid_amount) FROM claims c WHERE c.member_id = b.member_id AND c.claim_date >= b.idx_date), 0) AS rawcost_post,
    (SELECT COUNT(*) FROM encounters e WHERE e.member_id = b.member_id AND e.encounter_type = 'ED_VISIT' AND e.encounter_date <  b.idx_date) AS ed_pre,
    (SELECT COUNT(*) FROM encounters e WHERE e.member_id = b.member_id AND e.encounter_type = 'ED_VISIT' AND e.encounter_date >= b.idx_date) AS ed_post,
    (SELECT COUNT(*) FROM encounters e WHERE e.member_id = b.member_id AND e.encounter_type = 'INPATIENT_ADMIT' AND e.encounter_date <  b.idx_date) AS ip_pre,
    (SELECT COUNT(*) FROM encounters e WHERE e.member_id = b.member_id AND e.encounter_type = 'INPATIENT_ADMIT' AND e.encounter_date >= b.idx_date) AS ip_post
  FROM did_base b)
SELECT member_id, grp, idx_date,
       cost_pre / (t / 30.4) AS cost_pre_m,       cost_post / ((288 - t) / 30.4) AS cost_post_m,
       rawcost_pre / (t / 30.4) AS rawcost_pre_m, rawcost_post / ((288 - t) / 30.4) AS rawcost_post_m,
       1000.0 * ed_pre / (t / 30.4) AS ed_pre_m,  1000.0 * ed_post / ((288 - t) / 30.4) AS ed_post_m,
       1000.0 * ip_pre / (t / 30.4) AS ip_pre_m,  1000.0 * ip_post / ((288 - t) / 30.4) AS ip_post_m
FROM x;

DROP TABLE IF EXISTS r_did_groups;
CREATE TABLE r_did_groups AS
SELECT grp, COUNT(*) AS members,
       ROUND(AVG(cost_pre_m)) AS cost_capped_before, ROUND(AVG(cost_post_m)) AS cost_capped_after,
       ROUND(AVG(rawcost_pre_m)) AS cost_uncapped_before, ROUND(AVG(rawcost_post_m)) AS cost_uncapped_after,
       ROUND(AVG(ed_pre_m), 1) AS ed_before, ROUND(AVG(ed_post_m), 1) AS ed_after, ROUND(AVG(ip_pre_m), 1) AS ip_before, ROUND(AVG(ip_post_m), 1) AS ip_after
FROM did_member GROUP BY grp;

-- DiD = (treated after - before) - (comparison after - before). > 0 means treated use ROSE MORE than comparison.
DROP TABLE IF EXISTS r_did_estimates;
CREATE TABLE r_did_estimates AS
SELECT 'Paid $ per member-month (capped at P99 claim)' AS outcome,
       ROUND(AVG(CASE WHEN grp='treated' THEN cost_post_m - cost_pre_m END) - AVG(CASE WHEN grp='comparison' THEN cost_post_m - cost_pre_m END), 1) AS did FROM did_member
UNION ALL SELECT 'Paid $ per member-month (uncapped)',
       ROUND(AVG(CASE WHEN grp='treated' THEN rawcost_post_m - rawcost_pre_m END) - AVG(CASE WHEN grp='comparison' THEN rawcost_post_m - rawcost_pre_m END), 1) FROM did_member
UNION ALL SELECT 'ED visits per 1,000 member-months',
       ROUND(AVG(CASE WHEN grp='treated' THEN ed_post_m - ed_pre_m END) - AVG(CASE WHEN grp='comparison' THEN ed_post_m - ed_pre_m END), 1) FROM did_member
UNION ALL SELECT 'Admissions per 1,000 member-months',
       ROUND(AVG(CASE WHEN grp='treated' THEN ip_post_m - ip_pre_m END) - AVG(CASE WHEN grp='comparison' THEN ip_post_m - ip_pre_m END), 1) FROM did_member;

-- Robustness: drop the 5 treated members with the largest cost increase (cost result is driven by a few large claims)
DROP TABLE IF EXISTS r_did_robustness;
CREATE TABLE r_did_robustness AS
WITH tr AS (SELECT member_id, cost_post_m - cost_pre_m AS d FROM did_member WHERE grp = 'treated'),
     drop5 AS (SELECT member_id FROM tr ORDER BY d DESC LIMIT 5)
SELECT ROUND(AVG(CASE WHEN grp='treated' AND member_id NOT IN (SELECT member_id FROM drop5) THEN cost_post_m - cost_pre_m END)
           - AVG(CASE WHEN grp='comparison' THEN cost_post_m - cost_pre_m END), 1) AS did_cost_excluding_top5_treated FROM did_member;

-- (c) Dose-response within the treated group (first enrollment record per member)
DROP TABLE IF EXISTS r_cm_dose_response;
CREATE TABLE r_cm_dose_response AS
WITH f AS (SELECT c.*, ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY enrollment_date, enrollment_id) AS rn FROM care_mgmt c),
     d AS (SELECT f.*, m.cost_post_m - m.cost_pre_m AS d_cost, m.ed_post_m - m.ed_pre_m AS d_ed,
                  1.0 * successful_contacts / outreach_attempts AS contact_rate, 1.0 * goals_met / NULLIF(total_goals, 0) AS goal_rate
           FROM f JOIN did_member m ON m.member_id = f.member_id AND m.grp = 'treated' WHERE f.rn = 1)
SELECT 'Care plan created' AS marker, CASE WHEN care_plan_created = 1 THEN 'Yes' ELSE 'No' END AS grp, COUNT(*) AS n, ROUND(AVG(d_cost)) AS chg_cost_pmpm, ROUND(AVG(d_ed), 1) AS chg_ed_per_1000_mo FROM d GROUP BY 2
UNION ALL SELECT 'Contact rate >= 50%', CASE WHEN contact_rate >= 0.5 THEN 'Yes' ELSE 'No' END, COUNT(*), ROUND(AVG(d_cost)), ROUND(AVG(d_ed), 1) FROM d GROUP BY 2
UNION ALL SELECT 'Goal attainment >= 50%', CASE WHEN goal_rate >= 0.5 THEN 'Yes' ELSE 'No' END, COUNT(*), ROUND(AVG(d_cost)), ROUND(AVG(d_ed), 1) FROM d GROUP BY 2;

-- (d) Program operations ------------------------------------------------------------
DROP TABLE IF EXISTS r_cm_funnel;
CREATE TABLE r_cm_funnel AS
SELECT 1 AS step, 'Enrollments' AS stage, COUNT(*) AS n FROM care_mgmt
UNION ALL SELECT 2, 'Reached at least once', COUNT(*) FROM care_mgmt WHERE successful_contacts > 0
UNION ALL SELECT 3, 'Assessment completed', COUNT(*) FROM care_mgmt WHERE completed_assessments > 0
UNION ALL SELECT 4, 'Care plan created', COUNT(*) FROM care_mgmt WHERE care_plan_created = 1
UNION ALL SELECT 5, 'Has goals set', COUNT(*) FROM care_mgmt WHERE total_goals > 0
UNION ALL SELECT 6, 'Met >= 50% of goals', COUNT(*) FROM care_mgmt WHERE total_goals > 0 AND 1.0 * goals_met / total_goals >= 0.5
UNION ALL SELECT 7, 'Completed (status)', COUNT(*) FROM care_mgmt WHERE enrollment_status = 'COMPLETED';

DROP TABLE IF EXISTS r_cm_program_profile;
CREATE TABLE r_cm_program_profile AS
SELECT program_name, COUNT(*) AS enrollments, COUNT(DISTINCT member_id) AS members, ROUND(AVG(risk_score), 2) AS avg_risk_score,
       ROUND(1.0 * SUM(successful_contacts) / SUM(outreach_attempts), 3) AS contact_rate, ROUND(AVG(care_plan_created), 3) AS care_plan_rate,
       ROUND(1.0 * SUM(goals_met) / SUM(total_goals), 3) AS goal_attainment, ROUND(AVG(enrollment_status = 'COMPLETED'), 3) AS pct_completed,
       ROUND(AVG(enrollment_status = 'DISENROLLED'), 3) AS pct_disenrolled, ROUND(AVG(enrollment_status = 'ACTIVE'), 3) AS pct_active
FROM care_mgmt GROUP BY program_name;

-- Active enrollments by age (capacity tied up in stale enrollments)
DROP TABLE IF EXISTS r_cm_active_tenure;
CREATE TABLE r_cm_active_tenure AS
SELECT COUNT(*) AS active_enrollments,
       SUM(julianday((SELECT end_date FROM params)) - julianday(enrollment_date) > 180) AS older_than_180d,
       SUM(julianday((SELECT end_date FROM params)) - julianday(enrollment_date) > 365) AS older_than_365d,
       SUM(julianday((SELECT end_date FROM params)) - julianday(enrollment_date) > 180 AND care_plan_created = 0) AS older_180d_no_care_plan
FROM care_mgmt WHERE enrollment_status = 'ACTIVE';

DROP TABLE IF EXISTS r_cm_care_manager;
CREATE TABLE r_cm_care_manager AS
SELECT care_manager_id, COUNT(*) AS enrollments, ROUND(1.0 * SUM(successful_contacts) / SUM(outreach_attempts), 3) AS contact_rate,
       ROUND(1.0 * SUM(goals_met) / SUM(total_goals), 3) AS goal_attainment, ROUND(AVG(enrollment_status = 'COMPLETED'), 3) AS pct_completed
FROM care_mgmt GROUP BY care_manager_id ORDER BY goal_attainment;

-- Repeat enrollments in the same program that overlap in time (possible duplicate records)
DROP TABLE IF EXISTS r_cm_repeat_enrollments;
CREATE TABLE r_cm_repeat_enrollments AS
WITH x AS (SELECT member_id, program_name, enrollment_date,
                  LAG(COALESCE(disenrollment_date, (SELECT end_date FROM params))) OVER (PARTITION BY member_id, program_name ORDER BY enrollment_date) AS prev_end
           FROM care_mgmt)
SELECT SUM(prev_end IS NOT NULL) AS repeat_enrollments, SUM(enrollment_date < prev_end) AS overlapping_with_previous FROM x;

-- ################ 05_focus_areas.sql ################
-- =====================================================================================
-- 05_focus_areas.sql  |  Where to focus in 2026: spend drivers, chronic conditions, inpatient review, providers, denials, UM, trend
-- =====================================================================================
DROP TABLE IF EXISTS r_service_category;
CREATE TABLE r_service_category AS
SELECT service_category, COUNT(*) AS claims, ROUND(SUM(paid_amount)) AS paid, ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1) AS pct_of_paid,
       ROUND(AVG(paid_amount)) AS avg_paid_per_claim, ROUND(100.0 * AVG(claim_status = 'DENIED'), 1) AS pct_denied
FROM claims GROUP BY service_category ORDER BY paid DESC;

DROP TABLE IF EXISTS r_condition_dx;
CREATE TABLE r_condition_dx AS
SELECT cond_group, COUNT(*) AS claims, COUNT(DISTINCT member_id) AS members, ROUND(SUM(paid_amount)) AS paid,
       ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1) AS pct_of_paid, ROUND(AVG(paid_amount)) AS paid_per_claim,
       ROUND(SUM(CASE WHEN service_category = 'INPATIENT' THEN paid_amount END)) AS inpatient_paid
FROM claims GROUP BY cond_group ORDER BY paid DESC;

-- Condition cohorts (a member can be in several): all-claims cost per member vs other members
DROP TABLE IF EXISTS r_condition_cohorts;
CREATE TABLE r_condition_cohorts AS
WITH L AS (
  SELECT 'Diabetes' AS cond, member_id, has_diabetes AS has, paid, ip_admits, ed_visits, readmits, cm_ever, preventive_visits FROM member_facts UNION ALL
  SELECT 'Cardiac', member_id, has_cardiac, paid, ip_admits, ed_visits, readmits, cm_ever, preventive_visits FROM member_facts UNION ALL
  SELECT 'Hypertension', member_id, has_hypertension, paid, ip_admits, ed_visits, readmits, cm_ever, preventive_visits FROM member_facts UNION ALL
  SELECT 'Asthma', member_id, has_asthma, paid, ip_admits, ed_visits, readmits, cm_ever, preventive_visits FROM member_facts UNION ALL
  SELECT 'COPD', member_id, has_copd, paid, ip_admits, ed_visits, readmits, cm_ever, preventive_visits FROM member_facts)
SELECT cond, SUM(has) AS members, ROUND(SUM(CASE WHEN has = 1 THEN paid END) / SUM(has)) AS paid_per_member,
       ROUND((SUM(CASE WHEN has = 1 THEN paid END) / SUM(has)) / (SUM(CASE WHEN has = 0 THEN paid END) / SUM(1 - has)), 2) AS vs_other_members,
       ROUND(100.0 * SUM(CASE WHEN has = 1 THEN paid END) / (SELECT SUM(paid) FROM member_facts), 1) AS pct_of_total_cost,
       ROUND(100.0 * SUM(CASE WHEN has = 1 THEN ip_admits END) / SUM(has)) AS admits_per_100, ROUND(100.0 * SUM(CASE WHEN has = 1 THEN ed_visits END) / SUM(has)) AS ed_per_100,
       SUM(CASE WHEN has = 1 THEN readmits END) AS readmits, ROUND(100.0 * SUM(CASE WHEN has = 1 THEN cm_ever END) / SUM(has), 1) AS pct_in_cm,
       ROUND(100.0 * SUM(CASE WHEN has = 1 AND preventive_visits > 0 THEN 1 END) / SUM(has), 1) AS pct_with_preventive_visit
FROM L GROUP BY cond ORDER BY paid_per_member DESC;

-- Members with any chronic condition: share of members vs share of cost
DROP TABLE IF EXISTS r_chronic_vs_cost;
CREATE TABLE r_chronic_vs_cost AS
SELECT CASE WHEN n_chronic > 0 THEN '>=1 chronic condition' ELSE 'None' END AS grp, COUNT(*) AS members,
       ROUND(100.0 * SUM(paid) / (SELECT SUM(paid) FROM member_facts), 1) AS pct_of_cost, ROUND(100.0 * AVG(preventive_visits > 0), 1) AS pct_with_preventive_visit
FROM member_facts GROUP BY 1;

-- Inpatient diagnosis review: stays billed under routine / symptom diagnoses
DROP TABLE IF EXISTS r_inpatient_dx_review;
CREATE TABLE r_inpatient_dx_review AS
SELECT 'All inpatient claims' AS pool, COUNT(*) AS claims, ROUND(SUM(paid_amount)) AS paid, ROUND(AVG(paid_amount)) AS avg_paid,
       ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1) AS pct_of_all_paid FROM claims WHERE service_category = 'INPATIENT'
UNION ALL SELECT 'Non-specific / acute diagnosis', COUNT(*), ROUND(SUM(paid_amount)), ROUND(AVG(paid_amount)), ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1)
          FROM claims WHERE service_category = 'INPATIENT' AND cond_group = 'Non-specific / acute'
UNION ALL SELECT 'Routine exam Z00.00', COUNT(*), ROUND(SUM(paid_amount)), ROUND(AVG(paid_amount)), ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1)
          FROM claims WHERE service_category = 'INPATIENT' AND diagnosis_code = 'Z00.00'
UNION ALL SELECT 'Low-acuity pool (Z00.00, J06.9, R51)', COUNT(*), ROUND(SUM(paid_amount)), ROUND(AVG(paid_amount)), ROUND(100.0 * SUM(paid_amount) / (SELECT SUM(paid_amount) FROM claims), 1)
          FROM claims WHERE service_category = 'INPATIENT' AND diagnosis_code IN ('Z00.00', 'J06.9', 'R51');

-- Providers: observed / expected paid cost (expected = average paid for the same service category). Small samples: treat as a screen, not a ranking.
-- (The permutation test that shows provider spread is no bigger than chance, and the binomial denial test, are in the Python script.)
DROP TABLE IF EXISTS r_provider_oe;
CREATE TABLE r_provider_oe AS
WITH e AS (SELECT service_category, AVG(paid_amount) AS exp_paid FROM claims GROUP BY service_category)
SELECT c.provider_id, COUNT(*) AS claims, COUNT(DISTINCT c.member_id) AS members, ROUND(SUM(c.paid_amount)) AS paid,
       ROUND(SUM(c.paid_amount) / SUM(e.exp_paid), 2) AS observed_to_expected, ROUND(100.0 * AVG(c.claim_status = 'DENIED'), 1) AS pct_denied
FROM claims c JOIN e USING (service_category) GROUP BY c.provider_id ORDER BY paid DESC LIMIT 30;

DROP TABLE IF EXISTS r_provider_concentration;
CREATE TABLE r_provider_concentration AS
WITH p AS (SELECT provider_id, SUM(paid_amount) AS paid FROM claims GROUP BY provider_id), r AS (SELECT paid, ROW_NUMBER() OVER (ORDER BY paid DESC) AS rk FROM p)
SELECT COUNT(*) AS providers, ROUND(100.0 * SUM(CASE WHEN rk <= 20 THEN paid END) / SUM(paid), 1) AS top20_providers_pct_of_paid FROM r;

-- Facilities (inpatient): too few admissions each to rank; shown for completeness
DROP TABLE IF EXISTS r_facility_inpatient;
CREATE TABLE r_facility_inpatient AS
WITH a AS (SELECT facility_id, COUNT(*) AS admits, SUM(readmission_flag) AS readmits, ROUND(AVG(length_of_stay), 1) AS alos FROM encounters WHERE encounter_type = 'INPATIENT_ADMIT' GROUP BY facility_id),
     c AS (SELECT facility_id, COUNT(*) AS ip_claims, ROUND(SUM(paid_amount)) AS ip_paid FROM claims WHERE service_category = 'INPATIENT' GROUP BY facility_id)
SELECT c.facility_id, COALESCE(a.admits, 0) AS admits, COALESCE(a.readmits, 0) AS readmits, a.alos, c.ip_claims, c.ip_paid FROM c LEFT JOIN a USING (facility_id) ORDER BY ip_paid DESC LIMIT 15;

-- Claim denials
DROP TABLE IF EXISTS r_claim_denials;
CREATE TABLE r_claim_denials AS
SELECT denial_reason, COUNT(*) AS claims, ROUND(SUM(allowed_amount)) AS allowed_value, ROUND(SUM(member_responsibility)) AS member_responsibility_on_denied
FROM claims WHERE claim_status = 'DENIED' GROUP BY denial_reason ORDER BY allowed_value DESC;

-- Utilization management
DROP TABLE IF EXISTS r_um_by_service;
CREATE TABLE r_um_by_service AS
SELECT service_type, COUNT(*) AS requests, ROUND(100.0 * AVG(decision = 'DENIED'), 1) AS pct_denied, ROUND(100.0 * AVG(decision = 'PENDING'), 1) AS pct_pending,
       ROUND(AVG(tat_days), 2) AS avg_tat_days, ROUND(100.0 * AVG(appeal_flag), 1) AS pct_appealed
FROM um GROUP BY service_type ORDER BY pct_denied DESC;

DROP TABLE IF EXISTS r_um_summary;
CREATE TABLE r_um_summary AS
SELECT ROUND(100.0 * SUM(decision = 'DENIED') / SUM(decision <> 'PENDING'), 1) AS denial_rate_of_decided_pct,          -- denominator excludes PENDING
       SUM(decision = 'DENIED') AS denials, SUM(appeal_flag) AS appeals, ROUND(100.0 * SUM(appeal_flag) / SUM(decision = 'DENIED'), 1) AS appeal_rate_pct,
       SUM(appeal_outcome = 'OVERTURNED') AS overturned, SUM(appeal_outcome = 'UPHELD') AS upheld,
       ROUND(100.0 * SUM(appeal_outcome = 'OVERTURNED') / SUM(appeal_outcome IN ('OVERTURNED', 'UPHELD')), 1) AS overturn_rate_of_decided_appeals_pct,
       ROUND(AVG(tat_days), 2) AS avg_tat_days FROM um;

DROP TABLE IF EXISTS r_um_urgent_turnaround;
CREATE TABLE r_um_urgent_turnaround AS
SELECT urgency, COUNT(*) AS requests, ROUND(AVG(tat_days), 2) AS avg_tat_days, ROUND(100.0 * AVG(tat_days > 3), 1) AS pct_over_3_days, ROUND(100.0 * AVG(decision = 'DENIED'), 1) AS pct_denied
FROM um GROUP BY urgency;

-- Monthly cost (incurred basis), per member per month on a 30.4-day basis. Sep/Oct are incomplete (claims arrive ~27 days after service; Oct = 15 days).
DROP TABLE IF EXISTS r_monthly_trend;
CREATE TABLE r_monthly_trend AS
SELECT claim_month, COUNT(*) AS claims, ROUND(SUM(paid_amount)) AS paid, ROUND(SUM(paid_amount) / 1000.0) AS paid_pmpm,
       ROUND(SUM(paid_amount) / 1000.0 * 30.4 / CASE WHEN claim_month = '2025-10' THEN 15 ELSE CAST(strftime('%d', date(claim_month || '-01', '+1 month', '-1 day')) AS INTEGER) END) AS paid_pmpm_30_4_day_basis,
       ROUND(100.0 * SUM(CASE WHEN service_category = 'INPATIENT' THEN paid_amount END) / SUM(paid_amount), 1) AS inpatient_share_pct
FROM claims GROUP BY claim_month ORDER BY claim_month;

DROP TABLE IF EXISTS r_ed_preventive;
CREATE TABLE r_ed_preventive AS
SELECT SUM(ed_visits > 0) AS members_with_ed_visit, SUM(ed_visits >= 3) AS members_with_3plus_ed,
       ROUND(100.0 * SUM(CASE WHEN ed_visits >= 3 THEN ed_visits END) / SUM(ed_visits), 1) AS pct_of_ed_visits_from_3plus,
       ROUND(100.0 * AVG(preventive_visits > 0), 1) AS pct_members_with_preventive_visit FROM member_facts;

-- ################ 06_ops_reconciliation.sql ################
-- =====================================================================================
-- 06_ops_reconciliation.sql  |  Re-derive ops statuses with explicit direction (+/-5% band) and reconcile to the detail tables
-- =====================================================================================
DROP TABLE IF EXISTS ops_rederived;
CREATE TABLE ops_rederived AS
WITH d AS (
  SELECT *, CASE WHEN metric_name IN ('Average Call Wait Time','Hospital Readmission Rate','Prior Authorization Turnaround Time','Medical Loss Ratio','Emergency Department Visit Rate') THEN -1 ELSE 1 END AS dir,
            (metric_value / target_value - 1) * 100 AS pct_vs_target FROM ops)   -- dir = -1 where lower is favourable (MLR treated as lower = better)
SELECT metric_date, metric_name, metric_category, metric_value, target_value, performance_status AS status_in_file, ROUND(dir * pct_vs_target, 1) AS favourable_pct,
       CASE WHEN dir * pct_vs_target > 5 THEN 'FAVORABLE' WHEN dir * pct_vs_target < -5 THEN 'UNFAVORABLE' ELSE 'ON_TARGET' END AS status_rederived
FROM d;

DROP TABLE IF EXISTS r_ops_summary;
CREATE TABLE r_ops_summary AS
SELECT metric_name, ROUND(AVG(metric_value), 2) AS avg_value, MAX(target_value) AS target, SUM(status_rederived = 'UNFAVORABLE') AS months_unfavourable,
       SUM(status_rederived = 'FAVORABLE') AS months_favourable, SUM(status_in_file <> CASE status_rederived WHEN 'FAVORABLE' THEN 'ABOVE_TARGET' WHEN 'UNFAVORABLE' THEN 'BELOW_TARGET' ELSE 'ON_TARGET' END) AS months_label_differs_from_file
FROM ops_rederived GROUP BY metric_name ORDER BY months_unfavourable DESC;

-- Recompute reported metrics from the detail files (monthly average) and compare with ops.csv
DROP TABLE IF EXISTS r_ops_reconciliation;
CREATE TABLE r_ops_reconciliation AS
WITH months AS (SELECT DISTINCT substr(metric_date, 1, 7) AS m FROM ops),
ed AS (SELECT substr(encounter_date, 1, 7) AS m, COUNT(*) AS v FROM encounters WHERE encounter_type = 'ED_VISIT' GROUP BY 1),
rd AS (SELECT substr(admission_date, 1, 7) AS m, 100.0 * SUM(readmission_flag) / COUNT(*) AS v FROM encounters WHERE encounter_type = 'INPATIENT_ADMIT' GROUP BY 1),
pa AS (SELECT substr(request_date, 1, 7) AS m, AVG(tat_days) AS v FROM um GROUP BY 1),
cmm AS (SELECT months.m, 100.0 * (SELECT COUNT(DISTINCT member_id) FROM care_mgmt c WHERE c.enrollment_date <= date(months.m || '-01', '+1 month', '-1 day')
                                  AND (c.disenrollment_date IS NULL OR c.disenrollment_date >= months.m || '-01')) / 1000.0 AS v FROM months),
o AS (SELECT substr(metric_date, 1, 7) AS m, metric_name, metric_value FROM ops)
SELECT 'ED visits per 1,000 members per month' AS metric, ROUND((SELECT AVG(v) FROM ed), 1) AS recomputed, ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Emergency Department Visit Rate'), 1) AS reported_in_ops
UNION ALL SELECT 'Readmission rate % (flag as provided)', ROUND((SELECT AVG(v) FROM rd), 1), ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Hospital Readmission Rate'), 1)
UNION ALL SELECT 'Prior-auth turnaround, days', ROUND((SELECT AVG(v) FROM pa), 2), ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Prior Authorization Turnaround Time'), 2)
UNION ALL SELECT 'Care-management members, % active in month', ROUND((SELECT AVG(v) FROM cmm), 1), ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Care Management Enrollment Rate'), 1)
UNION ALL SELECT 'Care-management members, % ever enrolled', ROUND(100.0 * (SELECT AVG(cm_ever) FROM member_facts), 1), ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Care Management Enrollment Rate'), 1)
UNION ALL SELECT 'Preventive care: % members with >=1 preventive visit (YTD) vs ops completion rate', ROUND(100.0 * (SELECT AVG(preventive_visits > 0) FROM member_facts), 1), ROUND((SELECT AVG(metric_value) FROM o WHERE metric_name = 'Preventive Care Completion Rate'), 1);
