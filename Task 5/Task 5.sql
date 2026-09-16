WITH monthly_segment_performance AS (
    SELECT 
        TO_CHAR(t.created_at, 'YYYY-MM') AS month_cohort,
        m.pricing_plan,
        t.route_id,
        COUNT(CASE WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN 1 END) AS successful_txns,
        SUM(t.amount * COALESCE(fx.rate_to_usd, 1.0)) AS successful_gpv_usd,
        
        -- Calculated Unit Economics
        SUM(
            ((t.amount * CASE WHEN m.pricing_plan = 'Volume_Custom' THEN 0.015 ELSE 0.025 END)
            - (r.fixed_fee + (t.amount * r.variable_fee_pct))) * COALESCE(fx.rate_to_usd, 1.0)
        ) / NULLIF(COUNT(CASE WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN 1 END), 0) AS cpst_usd

    FROM PAYMENTS_ANALYTICS.PUBLIC.transaction t
    JOIN PAYMENTS_ANALYTICS.PUBLIC.merchant m ON t.merchant_id = m.merchant_id
    JOIN PAYMENTS_ANALYTICS.PUBLIC.route_cost r ON t.route_id = r.route_id
    LEFT JOIN PAYMENTS_ANALYTICS.PUBLIC.fx_rate fx 
        ON CAST(t.created_at AS DATE) = fx.rate_date 
       AND t.currency = fx.currency 
       AND fx.rate_type = 'EOD_SPOT'
    WHERE t.status = 'AUTHORIZED' AND t.amount > 0
    GROUP BY 1, 2, 3
)
SELECT 
    month_cohort,
    pricing_plan,
    route_id,
    successful_txns,
    RATIO_TO_REPORT(successful_txns) OVER (PARTITION BY month_cohort) AS volume_share,
    cpst_usd
FROM monthly_segment_performance
ORDER BY month_cohort ASC, volume_share DESC;


