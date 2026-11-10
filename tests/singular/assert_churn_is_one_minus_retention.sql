-- churn_rate must equal 1 - retention_rate, and month 0 retention must be exactly 1.
select *
from {{ ref('mart_cohort_retention') }}
where abs(churn_rate - (1 - retention_rate)) > 0.000001
    or (months_since_acquisition = 0 and retention_rate <> 1)
