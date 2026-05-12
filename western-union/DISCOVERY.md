# Western Union -- Pre-Session Discovery Questions

> Questions to ground the engagement in WU's actual architecture, pain points, and definition of success.

## Known Context

- Snowflake customer since 2019
- Matillion ETL (primary transformation engine)
- Multi-region deployment (US, EMEA, APAC corridors)
- Monte Carlo Advisory Board member (Surekha)
- Patent holder: configurable functions to harmonize data from disparate sources
- Built Azure data platform at Walgreens (prior role)
- Current concern: accelerating data usage without losing stakeholders to quality issues

## Source Systems & Architecture

1. How many source systems feed your Snowflake environment today? Which are the top 3 by volume?
2. What does your current ingestion pattern look like -- Matillion for everything, or a mix of tools?
3. Do you run a medallion architecture (RAW/CURATED/SEMANTIC) or a different layering model?
4. How many Snowflake accounts are in play? Is there a dev/staging/prod separation?
5. What's your current Dynamic Table adoption? Any, or still primarily scheduled ELT?

## Data Quality & Fidelity

6. What are the top 3 data quality failures your team deals with today?
7. How do you currently detect quality issues -- Monte Carlo alerts, manual checks, user complaints?
8. When a quality issue is detected, what's the remediation workflow? Manual fix, ticket, automated?
9. What percentage of your data engineering time goes to quality firefighting vs. new pipeline development?
10. Are there specific compliance-driven quality requirements (BSA/AML, PCI-DSS, GDPR) that drive monitoring?

## Semantic Layer & Trust

11. What does your current semantic layer look like? Views, BI tool semantic models, or no formal layer?
12. Who defines what "correct" means for a given metric -- business, data engineering, or ad hoc?
13. How do you handle conflicting definitions of the same metric across teams?
14. What's your current approach to data contracts or SLAs between producers and consumers?

## Governance & Access

15. How do you manage PII masking today -- column-level policies, view-based, or application-layer?
16. Is row-level security in use? If so, what dimensions (region, business unit, customer tier)?
17. What does your role hierarchy look like for data access? How many distinct access personas?
18. Are governance policies consistent across dev/staging/prod, or does each environment have its own?

## Pipeline Automation & SDLC

19. How do you promote pipelines from dev to prod today? Git-based, manual, or tool-specific?
20. What's your CI/CD maturity for data pipelines? Any automated testing or validation gates?
21. How long does it take to go from a business requirement to a deployed pipeline? Days, weeks, months?
22. Is your team using Cortex Code or any AI-assisted development tools today?

## DMF & Monitoring Coverage

23. Are you using Snowflake Data Metric Functions today, or relying entirely on Monte Carlo?
24. What's your current monitoring coverage -- percentage of tables with active quality checks?
25. Do you have freshness SLAs defined for critical tables? How are they enforced?
26. Is there a data quality scorecard or dashboard that leadership reviews?

## Success Definition

27. If this engagement succeeds, what does Surekha present to the board in 6 months?
28. What would make your data engineers say "this changed how we work"?
29. Is there a specific pipeline or use case you'd want to pilot first?
30. What's the one thing that, if we solved it in these sessions, would justify the entire engagement?
