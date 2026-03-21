# United Rentals — Architecture Strategy

> Target architecture design, comparison scorecards, and mapping of DCA patterns to UR's specific requirements.

## Strategic Thesis

Most of UR's operational friction originates from **physical account boundaries creating artificial data movement and governance fragmentation**. The "Heroics" experienced by the team are an architectural symptom, not a people problem.

The solution is a **Federated Data Platform** built on the Container-by-DB pattern, unified governance via Snowflake Horizon, and an internal marketplace for self-service data consumption — eliminating the need for manual data movement between accounts.

## Architecture Principles

These principles are adapted from the core DCA framework to UR's specific context:

| Principle | UR Application |
|-----------|---------------|
| **Minimize Data Movement** | Eliminate ETL between Discovery and Production; use live sharing instead of data copies |
| **Interoperability and Flexibility** | Support Fivetran, Dynamic Tables, dbt, and Cortex AI within one federated topology |
| **Reduce Infrastructure Management** | Replace Wherescape Red with declarative transformations (Dynamic Tables) or code-first (dbt) |
| **Built-in HA/DR/Redundancy** | Leverage Snowflake's native replication instead of custom backup processes |
| **Governed Semantic Layer** | Snowflake Horizon governance + Cortex Analyst semantic views for branch-level AI access |

## Architecture Evolution — Three Stages

### Stage 1: Current State (Fragmented Multi-Account)

```mermaid
flowchart LR
    EDW["EDW PROD\nLocal Auth\nWherescape\n3 tenants"] -->|"Data Share\n(read-only)"| DISC["DISCOVERY\nSSO + RLS\nCortex AI\nBranch users"]
    EDW_DEV["EDW DEV\nMirror"]
    EDW -.->|"Manual copies"| DISC
```

### Stage 2: Unified (Container-by-DB in Single Hub)

```mermaid
flowchart TB
    subgraph HUB["PRIMARY HUB ACCOUNT — Unified Identity (SSO)"]
        EDW["EDW\nRAW →\nCURATED →\nSEMANTIC"]
        MANNING["Manning\nRAW →\nCURATED →\nSEMANTIC"]
        SOPS["Sales Ops\nRAW →\nCURATED →\nSEMANTIC"]
        CORTEX["Cortex\nModels\nFeature\nStore"]
        subgraph HORIZON["SNOWFLAKE HORIZON GOVERNANCE"]
            GOV["Tags | Masking | Row Access | Lineage | Catalog"]
        end
    end
```

### Stage 3: Federated Platform with Marketplace

```mermaid
flowchart TB
    subgraph IDENTITY["UNIFIED IDENTITY PLANE"]
        subgraph HUB["PRIMARY HUB (Container-by-DB)"]
            DOMAINS["EDW | Manning | Sales Ops | Fleet | Telematics | Cortex\nEach domain: RAW → CURATED → SEMANTIC"]
        end
        subgraph EXCHANGE["UR PRIVATE DATA EXCHANGE"]
            PROVIDERS["Internal Providers: Fleet, Telematics, Maintenance, Ops"]
            CONSUMERS["Internal Consumers: Analytics, AI/ML, Branch Apps"]
            EXTERNAL["External Sources: OEM Telematics, Weather, Economic Data"]
        end
        subgraph HORIZON["SNOWFLAKE HORIZON (Federated Governance)"]
            POLICIES["Policies defined once → follow data across the exchange"]
        end
    end
    HUB --> EXCHANGE
```

## Architecture Comparison Scorecard

This scorecard captures the evolution from UR's current friction to a federated data platform:

| Capability | Current State (Fragmented) | Stage 2 (Unified / Container-by-DB) | Stage 3 (Federation + Marketplace) | Strategic Impact |
|-----------|---------------------------|--------------------------------------|-------------------------------------|-----------------|
| **Data Movement** | Manual ETL; "Heroics" in Wherescape/Python | Logical separation; zero-copy cloning within one account | Live Data Sharing via Internal Marketplace; no ETL across accounts | Eliminates data latency and storage duplication |
| **Governance** | Localized/Inconsistent; siloed security policies | Centralized via Snowflake Horizon in a single hub | Federated — policies defined once, follow data across the exchange | Scales security without bottlenecking domain owners |
| **Data Discovery** | Word-of-mouth; users "ask" for access to tables | Catalog-driven; centralized metadata search | Self-Service Marketplace — users "Browse & Subscribe" to certified data products | Moves UR from "Ticket Culture" to "Product Culture" |
| **External Data** | Brittle APIs/SFTP; high maintenance for 3rd party | Traditional data loading into the unified hub | External Marketplace Access — instant mounting of OEM/Weather/Market data | Faster time-to-insight for Fleet & Telematics enrichment |
| **AI Readiness** | Fragmented context; AI models lack holistic data access | Unified context; Cortex-ready data in a single account | Federated AI — Cortex models run across the mesh with full governance | Enables "Branch Manager AI" with a 360-degree view |

## Container-by-DB Pattern — Applied to UR

The Container-by-DB pattern treats each database as a logical container whose boundaries are **contract boundaries**, not physical account walls. For UR, this means:

```mermaid
flowchart TB
    subgraph HUB["PRIMARY HUB ACCOUNT"]
        subgraph EDW["EDW Domain"]
            RAW_EDW["RAW_EDW\n(landing)"] -->|"Dynamic Tables\nor dbt"| CUR_EDW["CURATED_EDW"]
            CUR_EDW --> SEM_EDW["SEMANTIC_EDW\n+ Cortex"]
        end
        subgraph MANNING["Manning Domain"]
            RAW_MAN["RAW_MAN\n(landing)"] -->|"Dynamic Tables\nor dbt"| CUR_MAN["CURATED_MANNING"]
            CUR_MAN --> SEM_MAN["SEMANTIC_MANNING\n+ Cortex"]
        end
        subgraph SOPS["Sales Ops Domain"]
            RAW_SOPS["RAW_SOPS"] --> CUR_SOPS["CURATED_SOPS"]
            CUR_SOPS --> SEM_SOPS["SEMANTIC_SOPS"]
        end
        subgraph FLEET["Fleet / Telematics Domain"]
            RAW_FLEET["RAW_FLEET\nIoT / Telematics"] --> CUR_FLEET["CURATED_FLEET"]
            CUR_FLEET --> SEM_FLEET["SEMANTIC_FLEET"]
        end
        NOTE["Each domain owns its RAW → CURATED → SEMANTIC progression\nGovernance tags and policies applied uniformly via Horizon\nData contracts enforce quality and schema at domain boundaries"]
    end
    RAW_EDW -.->|"Fivetran\ningest"| RAW_EDW
    RAW_MAN -.->|"Fivetran\ningest"| RAW_MAN
```

**Key advantages for UR**:
- Manning and Sales Ops get autonomous dev/prod cycles without leaving the hub
- Each domain's Git repo controls its own transformations
- Zero-copy cloning provides instant dev/test environments per domain
- Governance policies apply once at the Horizon level, not per-account

## Transformation Strategy — Replacing Wherescape Red

UR's current Wherescape Red dependency can be replaced with a hybrid approach:

| Approach | Best For | UR Application |
|----------|---------|----------------|
| **Dynamic Tables** | Declarative, zero-orchestration, SLA-driven | Fleet utilization metrics, real-time telematics aggregations, operational dashboards |
| **dbt** | Code-first, test-driven, Git-native, existing team skills | EDW core models, complex business logic, teams already familiar with SQL-based transformation tools |
| **Hybrid** | Different domains choose their engine | Fleet/Telematics on Dynamic Tables (real-time); EDW/Manning on dbt (complex logic) |

See [DBT_VS_DYNAMIC_TABLES.md](../../docs/DBT_VS_DYNAMIC_TABLES.md) for the full comparison framework.

## Internal Marketplace Design

The UR Private Data Exchange enables domain teams to publish and consume data products without ETL:

```mermaid
flowchart LR
    subgraph PROVIDERS["PROVIDERS (Publish)"]
        FLEET["Fleet Domain"]
        TELEM["Telematics"]
        EDW_CORE["EDW Core"]
        EXT["EXTERNAL\nOEM Telemetry\nWeather Data\nEconomic Data"]
    end
    subgraph PRODUCTS["Data Products"]
        FU["Fleet Utilization"]
        AM["Asset Master"]
        SS["Sensor Streams"]
        FA["Fault Alerts"]
        C360["Customer 360"]
        REV["Revenue Metrics"]
    end
    subgraph CONSUMERS["CONSUMERS (Subscribe)"]
        ANALYTICS["Analytics Team\nBranch Managers\nFinance"]
        AI_ML["AI/ML (Cortex)\nMaintenance Ops"]
        SALES["Sales Ops\nRegional Directors"]
        FLEET_OPT["Fleet Optimization\nDemand Forecasting\nPricing Models"]
    end
    FLEET --> FU --> ANALYTICS
    FLEET --> AM --> ANALYTICS
    TELEM --> SS --> AI_ML
    TELEM --> FA --> AI_ML
    EDW_CORE --> C360 --> SALES
    EDW_CORE --> REV --> SALES
    EXT -->|"Marketplace"| FLEET_OPT
```

## Snowflake Horizon — Governance That Follows the Data

In the federated model, governance policies are defined once at the source domain and **travel with the data product** when shared via the marketplace:

| Governance Layer | Implementation | UR Application |
|-----------------|----------------|----------------|
| **Object Tags** | `DATA_CLASSIFICATION`, `PII_TYPE`, `AI_ALLOWED` | Tag contract pricing as CONFIDENTIAL, customer PII as SENSITIVE, fleet telemetry as INTERNAL |
| **Masking Policies** | Dynamic column masking based on role | Mask customer SSN/EIN for all non-PII_VIEWER roles; mask contract pricing for external partners |
| **Row Access Policies** | Filter rows by region, branch, or customer segment | Branch managers see only their region's data; regional directors see their territory |
| **Lineage** | ACCESS_HISTORY + Snowflake Horizon catalog | End-to-end tracing from Fivetran ingestion through Cortex AI outputs |
| **Data Contracts** | Schema + quality + SLA contracts at domain boundaries | Fleet domain publishes utilization data with guaranteed freshness SLA and quality tests |

## Cortex AI Pipeline — Discovery to Production

```mermaid
flowchart LR
    subgraph DISCOVERY["DISCOVERY (Experiment)"]
        PM_MVP["Predictive\nMaintenance\nModel (MVP)"]
        FO_MVP["Fleet\nOptimization\nModel (MVP)"]
        FS_EXP["Feature Store\n(Experiment)"]
    end
    subgraph PRODUCTION["PRODUCTION (Operationalize)"]
        PM_PROD["Predictive\nMaintenance\nModel (Prod)"]
        FO_PROD["Fleet\nOptimization\nModel (Prod)"]
        FS_PROD["Feature Store\n(Production)"]
    end
    PM_MVP -->|"CI/CD\nPromote"| PM_PROD
    FO_MVP -->|"CI/CD\nPromote"| FO_PROD
    FS_EXP <--> FS_PROD
    PM_PROD --> CORTEX
    FO_PROD --> CORTEX
    CORTEX["Cortex Analyst\n(Semantic Views)\nBranch Manager:\n'What assets can I\nrent within 50mi?'"]
```

The key insight: branch managers access AI-powered answers through **Cortex Analyst + Semantic Views**, governed by the same Snowflake Horizon policies that protect the underlying data. No separate AI access layer needed.

## References

- [Core DCA Architecture](../../docs/ARCHITECTURE.md)
- [SDLC & Deployment Patterns](../../docs/SDLC_ARCHITECTURE.md)
- [dbt vs Dynamic Tables](../../docs/DBT_VS_DYNAMIC_TABLES.md)
- [Governance Framework](../../docs/GOVERNANCE.md)
- [Account Architecture Patterns](../../docs/snowflake_account_architecture_patterns.md)
