WITH deduped_fraud AS (
    -- Deduplicate 1:N fraud decisions, taking the latest decision per transaction
    SELECT 
        transaction_id,
        rule_id,
        decision,
        CASE 
            WHEN risk_score < 0 THEN NULL
            WHEN risk_score > 1.0 AND risk_score <= 100.0 THEN risk_score / 100.0
            WHEN risk_score > 100.0 THEN NULL
            ELSE risk_score 
        END AS sanitized_risk_score,
        model_version
    FROM PAYMENTS_ANALYTICS.PUBLIC.fraud_decision
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY transaction_id 
        ORDER BY CASE WHEN decision = 'REJECT' THEN 1 ELSE 2 END
    ) = 1
),

aggregated_settlement AS (
    -- Aggregate 1:N split settlements back to 1:1 transaction grain
    SELECT 
        transaction_id,
        SUM(settlement_amount) AS total_settled_amount,
        SUM(fee_amount) AS total_withheld_fee,
        MAX(settlement_date) AS final_settlement_date,
        COUNT(*) AS settlement_tranche_count
    FROM PAYMENTS_ANALYTICS.PUBLIC.settlement
    GROUP BY transaction_id
),

aggregated_chargebacks AS (
    -- Aggregate chargeback claims per transaction
    SELECT 
        transaction_id,
        SUM(amount) AS total_chargeback_amount,
        COUNT(*) AS chargeback_count
    FROM PAYMENTS_ANALYTICS.PUBLIC.chargeback
    GROUP BY transaction_id
),

fx_baseline AS (
    -- Filter FX rates strictly to EOD_SPOT to prevent M:N join explosion
    SELECT 
        rate_date,
        currency,
        rate_to_usd
    FROM PAYMENTS_ANALYTICS.PUBLIC.fx_rate
    WHERE rate_type = 'EOD_SPOT'
)

SELECT 
    t.transaction_id,
    t.created_at,
    CAST(t.created_at AS DATE) AS transaction_date,
    COALESCE(t.merchant_id, 'MERCH_UNKNOWN') AS merchant_id,
    COALESCE(m.category, 'UNKNOWN') AS merchant_category,
    COALESCE(m.pricing_plan, 'Tier_1_Default') AS pricing_plan,
    t.customer_id,
    c.country AS customer_country,
    c.segment AS customer_segment,
    t.route_id,
    r.provider AS route_provider,
    t.currency,
    t.status AS transaction_status,
    
    -- Data Quality Flags
    CASE 
        WHEN t.merchant_id IS NULL THEN TRUE ELSE FALSE 
    END AS flag_missing_merchant,
    CASE 
        WHEN t.amount <= 0 THEN TRUE ELSE FALSE 
    END AS flag_anomalous_amount,

    -- Normalized Transaction Amounts
    t.amount AS gross_amount_native,
    COALESCE(fx.rate_to_usd, 1.0) AS fx_rate_to_usd,
    ROUND(t.amount * COALESCE(fx.rate_to_usd, 1.0), 4) AS gross_amount_usd,

    -- Revenue Economics (Derived from Pricing Plan schedules)
    CASE 
        WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN
            CASE 
                WHEN m.pricing_plan = 'Tier_1_Default' THEN ROUND(t.amount * 0.025, 4)
                WHEN m.pricing_plan = 'Volume_Custom' THEN ROUND(t.amount * 0.015, 4)
                WHEN m.pricing_plan = 'IC_Plus' THEN ROUND(t.amount * 0.018, 4)
                ELSE ROUND(t.amount * 0.020, 4)
            END
        ELSE 0.00
    END AS gross_revenue_native,

    -- Route Costs
    CASE 
        WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN
            ROUND((r.fixed_fee + (t.amount * r.variable_fee_pct)), 4)
        ELSE 0.00
    END AS routing_cost_native,

    -- Settlement & Fee Attribution
    COALESCE(s.total_settled_amount, 0.00) AS settled_amount_native,
    COALESCE(s.total_withheld_fee, 0.00) AS processor_settlement_fee_native,
    COALESCE(cb.total_chargeback_amount, 0.00) AS chargeback_loss_native,

    -- Contribution Profit Calculation (USD Standardized)
    ROUND(
        (
            (CASE 
                WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN
                    CASE 
                        WHEN m.pricing_plan = 'Tier_1_Default' THEN (t.amount * 0.025)
                        WHEN m.pricing_plan = 'Volume_Custom' THEN (t.amount * 0.015)
                        WHEN m.pricing_plan = 'IC_Plus' THEN (t.amount * 0.018)
                        ELSE (t.amount * 0.020)
                    END
                ELSE 0.00
            END) 
            - (CASE WHEN t.status = 'AUTHORIZED' AND t.amount > 0 THEN (r.fixed_fee + (t.amount * r.variable_fee_pct)) ELSE 0 END)
            - COALESCE(s.total_withheld_fee, 0.00)
            - COALESCE(cb.total_chargeback_amount, 0.00)
        ) * COALESCE(fx.rate_to_usd, 1.0), 4
    ) AS contribution_profit_usd

FROM PAYMENTS_ANALYTICS.PUBLIC.transaction t
LEFT JOIN PAYMENTS_ANALYTICS.PUBLIC.merchant m 
    ON t.merchant_id = m.merchant_id
LEFT JOIN PAYMENTS_ANALYTICS.PUBLIC.customer c 
    ON t.customer_id = c.customer_id
LEFT JOIN PAYMENTS_ANALYTICS.PUBLIC.route_cost r 
    ON t.route_id = r.route_id
LEFT JOIN fx_baseline fx 
    ON CAST(t.created_at AS DATE) = fx.rate_date 
   AND t.currency = fx.currency
LEFT JOIN deduped_fraud f 
    ON t.transaction_id = f.transaction_id
LEFT JOIN aggregated_settlement s 
    ON t.transaction_id = s.transaction_id
LEFT JOIN aggregated_chargebacks cb 
    ON t.transaction_id = cb.transaction_id;