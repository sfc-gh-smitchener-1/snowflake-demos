# United Rentals — CI/CD RBAC & Environment Architecture Diagrams

> Mermaid diagrams for the database-as-a-container pattern, CI/CD role hierarchy, promotion pipeline, and clone lifecycle.

---

## 1. Complete Role Hierarchy (CI/CD + Business)

Shows how CI/CD service roles and business consumer roles coexist under a single `DATA_ADMIN` root. The critical design: deploy roles are **siblings under UR_PLATFORM_ADMIN**, not chained — a compromised DEV deployer cannot reach PROD.

```mermaid
graph TD
    ACCOUNTADMIN:::sysRole --> SYSADMIN:::sysRole
    SYSADMIN --> DATA_ADMIN:::adminRole

    %% CI/CD Branch
    DATA_ADMIN --> UR_PLATFORM_ADMIN:::cicdRole
    DATA_ADMIN --> UR_CLONE_PROVISIONER:::cicdRole

    UR_PLATFORM_ADMIN --> UR_CICD_DEPLOY_PROD:::prodRole
    UR_PLATFORM_ADMIN --> UR_CICD_DEPLOY_STG:::stgRole
    UR_PLATFORM_ADMIN --> UR_CICD_DEPLOY_DEV:::devRole
    UR_PLATFORM_ADMIN --> UR_CICD_VALIDATOR:::validatorRole

    %% Business Branch
    DATA_ADMIN --> UR_FLEET_MANAGER:::bizRole
    DATA_ADMIN --> UR_EXTERNAL_PARTNER:::extRole

    UR_FLEET_MANAGER --> UR_REGIONAL_DIRECTOR:::bizRole
    UR_FLEET_MANAGER --> UR_CORPORATE_ANALYST:::bizRole
    UR_REGIONAL_DIRECTOR --> UR_BRANCH_MANAGER:::bizRole

    %% Annotations
    UR_CICD_DEPLOY_PROD -.-|"PROD databases ONLY"| noteP["fa:fa-lock Environment-Scoped"]
    UR_CICD_DEPLOY_STG -.-|"STG databases ONLY"| noteS["fa:fa-lock Environment-Scoped"]
    UR_CICD_DEPLOY_DEV -.-|"DEV databases ONLY"| noteD["fa:fa-lock Environment-Scoped"]
    UR_CICD_VALIDATOR -.-|"SELECT across ALL envs"| noteV["fa:fa-eye Read-Only"]

    classDef sysRole fill:#6c757d,color:#fff,stroke:#495057
    classDef adminRole fill:#0d6efd,color:#fff,stroke:#0a58ca
    classDef cicdRole fill:#6610f2,color:#fff,stroke:#520dc2
    classDef prodRole fill:#dc3545,color:#fff,stroke:#b02a37
    classDef stgRole fill:#fd7e14,color:#fff,stroke:#ca6510
    classDef devRole fill:#198754,color:#fff,stroke:#146c43
    classDef validatorRole fill:#0dcaf0,color:#000,stroke:#0aa2c0
    classDef bizRole fill:#ffc107,color:#000,stroke:#cc9a06
    classDef extRole fill:#adb5bd,color:#000,stroke:#6c757d

    style noteP fill:none,stroke:none,color:#dc3545
    style noteS fill:none,stroke:none,color:#fd7e14
    style noteD fill:none,stroke:none,color:#198754
    style noteV fill:none,stroke:none,color:#0dcaf0
```

---

## 2. Database-as-a-Container: Environment Architecture

The single-account environment model. Each column is an environment (DEV, STG, PROD). Each row is a data layer (RAW, CURATED, SEMANTIC). Each **database is a container** — the environment boundary IS the database boundary.

```mermaid
graph TB
    subgraph ACCOUNT["SNOWFLAKE ACCOUNT (Single Account)"]
        direction TB

        subgraph DEV["DEVELOPMENT"]
            direction TB
            RAW_DEV["RAW_DEV<br/><i>UNITED_RENTALS</i>"]:::devDb
            CURATED_DEV["CURATED_DEV<br/><i>UNITED_RENTALS</i>"]:::devDb
            SEM_DEV["SEM_DEV<br/><i>UNITED_RENTALS</i>"]:::devDb
            RAW_DEV --> CURATED_DEV --> SEM_DEV
        end

        subgraph STG["STAGING"]
            direction TB
            RAW_STG["RAW_STG<br/><i>UNITED_RENTALS</i>"]:::stgDb
            CURATED_STG["CURATED_STG<br/><i>UNITED_RENTALS</i>"]:::stgDb
            SEM_STG["SEM_STG<br/><i>UNITED_RENTALS</i>"]:::stgDb
            RAW_STG --> CURATED_STG --> SEM_STG
        end

        subgraph PROD["PRODUCTION"]
            direction TB
            RAW_PROD["RAW_PROD<br/><i>UNITED_RENTALS</i>"]:::prodDb
            CURATED_PROD["CURATED_PROD<br/><i>UNITED_RENTALS</i>"]:::prodDb
            SEM_PROD["SEM_PROD<br/><i>UNITED_RENTALS</i>"]:::prodDb
            RAW_PROD --> CURATED_PROD --> SEM_PROD
        end

        subgraph GOV["GOVERNANCE (Shared)"]
            direction LR
            ENV_REG["ENVIRONMENT<br/>_REGISTRY"]:::govDb
            PROMO_LOG["PROMOTION<br/>_LOG"]:::govDb
            CLONE_REG["CLONE<br/>_REGISTRY"]:::govDb
        end

        %% Deploy roles targeting their environments
        DEPLOY_DEV["UR_CICD_DEPLOY_DEV<br/>ALL DDL"]:::devDeploy -.-> DEV
        DEPLOY_STG["UR_CICD_DEPLOY_STG<br/>ALL DDL"]:::stgDeploy -.-> STG
        DEPLOY_PROD["UR_CICD_DEPLOY_PROD<br/>ALL DDL"]:::prodDeploy -.-> PROD

        %% Validator reads everything
        VALIDATOR["UR_CICD_VALIDATOR<br/>SELECT only"]:::valDeploy -.-> DEV
        VALIDATOR -.-> STG
        VALIDATOR -.-> PROD
        VALIDATOR -.-> GOV

        %% Business roles read from PROD
        BIZ["Business Roles<br/>(Fleet Mgr, Analyst, etc.)"]:::bizAccess -.->|"SELECT"| PROD
    end

    classDef devDb fill:#d1e7dd,stroke:#198754,color:#0f5132
    classDef stgDb fill:#fff3cd,stroke:#fd7e14,color:#664d03
    classDef prodDb fill:#f8d7da,stroke:#dc3545,color:#842029
    classDef govDb fill:#cff4fc,stroke:#0dcaf0,color:#055160
    classDef devDeploy fill:#198754,color:#fff,stroke:#146c43
    classDef stgDeploy fill:#fd7e14,color:#fff,stroke:#ca6510
    classDef prodDeploy fill:#dc3545,color:#fff,stroke:#b02a37
    classDef valDeploy fill:#0dcaf0,color:#000,stroke:#0aa2c0
    classDef bizAccess fill:#ffc107,color:#000,stroke:#cc9a06

    style ACCOUNT fill:#f8f9fa,stroke:#dee2e6,color:#212529
    style DEV fill:#d1e7dd22,stroke:#198754,stroke-width:2px,color:#0f5132
    style STG fill:#fff3cd22,stroke:#fd7e14,stroke-width:2px,color:#664d03
    style PROD fill:#f8d7da22,stroke:#dc3545,stroke-width:2px,color:#842029
    style GOV fill:#cff4fc22,stroke:#0dcaf0,stroke-width:2px,color:#055160
```

---

## 3. CI/CD Promotion Pipeline with Validation Gates

The end-to-end flow from a feature branch through DEV, STG, and PROD — with the four promotion gates. Each gate must pass before the next stage. Failed gates halt the pipeline and notify the developer.

```mermaid
flowchart LR
    subgraph GIT["Git Repository"]
        FB["Feature<br/>Branch"]
        DEV_BR["develop<br/>branch"]
        MAIN["main<br/>branch"]
        FB -->|"PR"| DEV_BR
        DEV_BR -->|"PR + Review"| MAIN
    end

    subgraph DEV_DEPLOY["DEV Environment"]
        DD["Deploy to<br/>*_DEV databases"]
        DT["Run unit tests<br/>in cloned data"]
    end

    subgraph GATES["Promotion Gates"]
        direction TB
        G1{"Gate 1<br/>Contract<br/>Validation"}
        G2{"Gate 2<br/>Governance<br/>Check"}
        G3{"Gate 3<br/>Peer<br/>Review"}
        G4{"Gate 4<br/>Integration<br/>Test"}
        G1 -->|"Pass"| G2
        G2 -->|"Pass"| G3
        G3 -->|"Approved"| G4
    end

    subgraph STG_DEPLOY["STG Environment"]
        SD["Deploy to<br/>*_STG databases"]
        IT["Integration<br/>tests"]
    end

    subgraph PROD_DEPLOY["PROD Environment"]
        PD["Deploy to<br/>*_PROD databases"]
        POST["Post-deploy:<br/>Log + Notify"]
    end

    FB -->|"UR_CICD_DEPLOY_DEV"| DD
    DD --> DT
    DT --> G1

    G4 -->|"UR_CICD_DEPLOY_STG"| SD
    SD --> IT

    IT -->|"UR_PLATFORM_ADMIN<br/>approval"| PD
    PD -->|"UR_CICD_DEPLOY_PROD"| POST

    %% Failure paths
    G1 -->|"Fail"| BLOCK1["Block &<br/>Notify"]
    G2 -->|"Fail"| BLOCK2["Block &<br/>Notify"]
    G3 -->|"Rejected"| BLOCK3["Back to<br/>Dev"]
    G4 -->|"Fail"| BLOCK4["Block &<br/>Notify"]

    style GIT fill:#e2e3e5,stroke:#6c757d,color:#212529
    style DEV_DEPLOY fill:#d1e7dd,stroke:#198754,color:#0f5132
    style GATES fill:#fff3cd,stroke:#ffc107,color:#664d03
    style STG_DEPLOY fill:#ffe5d0,stroke:#fd7e14,color:#664d03
    style PROD_DEPLOY fill:#f8d7da,stroke:#dc3545,color:#842029

    style BLOCK1 fill:#dc3545,color:#fff,stroke:#b02a37
    style BLOCK2 fill:#dc3545,color:#fff,stroke:#b02a37
    style BLOCK3 fill:#dc3545,color:#fff,stroke:#b02a37
    style BLOCK4 fill:#dc3545,color:#fff,stroke:#b02a37
```

---

## 4. Environment-Scoped Grant Model

The access control matrix visualized. Shows exactly what each role can do in each environment. This is the visual proof that **role-level isolation replaces account-level isolation**.

```mermaid
block-beta
    columns 4

    space:1 block:devhdr:1
        DEV_HDR["DEV"]
    end
    block:stghdr:1
        STG_HDR["STG"]
    end
    block:prodhdr:1
        PROD_HDR["PROD"]
    end

    block:r1:1
        DEPLOY_DEV_LABEL["UR_CICD<br/>_DEPLOY_DEV"]
    end
    block:r1d:1
        D1["ALL DDL"]
    end
    block:r1s:1
        D2["NONE"]
    end
    block:r1p:1
        D3["NONE"]
    end

    block:r2:1
        DEPLOY_STG_LABEL["UR_CICD<br/>_DEPLOY_STG"]
    end
    block:r2d:1
        S1["NONE"]
    end
    block:r2s:1
        S2["ALL DDL"]
    end
    block:r2p:1
        S3["NONE"]
    end

    block:r3:1
        DEPLOY_PROD_LABEL["UR_CICD<br/>_DEPLOY_PROD"]
    end
    block:r3d:1
        P1["NONE"]
    end
    block:r3s:1
        P2["NONE"]
    end
    block:r3p:1
        P3["ALL DDL"]
    end

    block:r4:1
        VALIDATOR_LABEL["UR_CICD<br/>_VALIDATOR"]
    end
    block:r4d:1
        V1["SELECT"]
    end
    block:r4s:1
        V2["SELECT"]
    end
    block:r4p:1
        V3["SELECT"]
    end

    block:r5:1
        PLATFORM_LABEL["UR_PLATFORM<br/>_ADMIN"]
    end
    block:r5d:1
        PA1["INHERIT"]
    end
    block:r5s:1
        PA2["INHERIT"]
    end
    block:r5p:1
        PA3["INHERIT"]
    end

    block:r6:1
        FLEET_LABEL["UR_FLEET<br/>_MANAGER"]
    end
    block:r6d:1
        FM1["SELECT"]
    end
    block:r6s:1
        FM2["NONE"]
    end
    block:r6p:1
        FM3["SELECT"]
    end

    style DEV_HDR fill:#198754,color:#fff
    style STG_HDR fill:#fd7e14,color:#fff
    style PROD_HDR fill:#dc3545,color:#fff

    style DEPLOY_DEV_LABEL fill:#198754,color:#fff
    style DEPLOY_STG_LABEL fill:#fd7e14,color:#fff
    style DEPLOY_PROD_LABEL fill:#dc3545,color:#fff
    style VALIDATOR_LABEL fill:#0dcaf0,color:#000
    style PLATFORM_LABEL fill:#6610f2,color:#fff
    style FLEET_LABEL fill:#ffc107,color:#000

    style D1 fill:#198754,color:#fff
    style D2 fill:#e9ecef,color:#6c757d
    style D3 fill:#e9ecef,color:#6c757d
    style S1 fill:#e9ecef,color:#6c757d
    style S2 fill:#fd7e14,color:#fff
    style S3 fill:#e9ecef,color:#6c757d
    style P1 fill:#e9ecef,color:#6c757d
    style P2 fill:#e9ecef,color:#6c757d
    style P3 fill:#dc3545,color:#fff
    style V1 fill:#cff4fc,color:#055160
    style V2 fill:#cff4fc,color:#055160
    style V3 fill:#cff4fc,color:#055160
    style PA1 fill:#e2d9f3,color:#3d0a70
    style PA2 fill:#e2d9f3,color:#3d0a70
    style PA3 fill:#e2d9f3,color:#3d0a70
    style FM1 fill:#fff3cd,color:#664d03
    style FM2 fill:#e9ecef,color:#6c757d
    style FM3 fill:#fff3cd,color:#664d03
```

---

## 5. Zero-Copy Clone Lifecycle

Shows how team dev environments are provisioned from PROD via cloning, used for development, and automatically cleaned up when their TTL expires.

```mermaid
sequenceDiagram
    autonumber

    participant Team as Domain Team<br/>(Manning, Sales Ops)
    participant Prov as UR_CLONE_PROVISIONER<br/>(Stored Procedure)
    participant Prod as PROD Databases<br/>(RAW/CURATED/SEM_PROD)
    participant Clone as Team Clone DBs<br/>(RAW/CURATED/SEM_TEAM_DEV)
    participant Reg as CLONE_REGISTRY<br/>(GOVERNANCE)
    participant Task as CLEANUP Task<br/>(Scheduled)

    Team->>Prov: CALL PROVISION_DEV_CLONE<br/>('MANNING', 'MANNING_ROLE', 14)

    Prov->>Prod: CREATE DATABASE RAW_MANNING_DEV<br/>CLONE RAW_PROD
    Prod-->>Clone: Zero-copy clone (instant)

    Prov->>Prod: CREATE DATABASE CURATED_MANNING_DEV<br/>CLONE CURATED_PROD
    Prod-->>Clone: Zero-copy clone (instant)

    Prov->>Prod: CREATE DATABASE SEM_MANNING_DEV<br/>CLONE SEM_PROD
    Prod-->>Clone: Zero-copy clone (instant)

    Prov->>Clone: GRANT ALL TO ROLE MANNING_ROLE
    Prov->>Clone: GRANT ALL TO ROLE UR_CICD_DEPLOY_DEV
    Prov->>Reg: INSERT clone records (TTL=14 days)

    Prov-->>Team: Clone set ready<br/>Expires in 14 days

    Note over Team,Clone: Team develops and tests in their clone

    loop Daily at 6 AM
        Task->>Reg: SELECT expired clones<br/>WHERE STATUS='ACTIVE'<br/>AND EXPIRES_AT < NOW()
        Reg-->>Task: List of expired clones
        Task->>Clone: DROP DATABASE IF EXISTS<br/>RAW_MANNING_DEV
        Task->>Reg: UPDATE STATUS='EXPIRED'
    end
```

---

## 6. Promotion Object Flow (CLONE / SWAP / DDL Methods)

Three strategies for moving objects from DEV to PROD. Each is logged to the `PROMOTION_LOG` with full audit context.

```mermaid
flowchart TD
    START["CALL PROMOTE_OBJECT<br/>(object_type, source, target,<br/>method, git_sha)"] --> DETECT{Detect Target<br/>Environment}

    DETECT --> ENV["Parse *_DEV / *_STG / *_PROD<br/>from target FQN"]

    ENV --> METHOD{Promotion<br/>Method?}

    METHOD -->|"CLONE"| CLONE["CREATE OR REPLACE table<br/>CURATED_PROD.UR.DIM_BRANCH<br/>CLONE CURATED_DEV.UR.DIM_BRANCH"]
    METHOD -->|"SWAP"| SWAP["ALTER TABLE<br/>CURATED_PROD.UR.FACT_RENTALS<br/>SWAP WITH<br/>CURATED_DEV.UR.FACT_RENTALS_V2"]
    METHOD -->|"DDL"| DDL["Pipeline executes SQL directly<br/>from Git repository<br/>(views, procedures, UDFs)"]
    METHOD -->|"Unknown"| FAIL["Log FAILED to<br/>PROMOTION_LOG<br/>Return error"]

    CLONE --> LOG
    SWAP --> LOG
    DDL --> LOG

    LOG["INSERT INTO PROMOTION_LOG<br/>promotion_id, user, role,<br/>source_env, target_env,<br/>object, method, git_sha,<br/>validation_passed, status"]

    LOG --> DONE["Return promotion_id"]

    style START fill:#6610f2,color:#fff,stroke:#520dc2
    style CLONE fill:#198754,color:#fff
    style SWAP fill:#fd7e14,color:#fff
    style DDL fill:#0d6efd,color:#fff
    style FAIL fill:#dc3545,color:#fff
    style LOG fill:#cff4fc,color:#055160,stroke:#0dcaf0
    style DONE fill:#d1e7dd,color:#0f5132,stroke:#198754
```

---

## 7. "AND World" — Layered Security Model

UR needs shared spaces AND department-locked AND user-only simultaneously. This shows how RBAC + RLS + Column Masking combine to create the "AND world" across both CI/CD and business access.

```mermaid
flowchart TB
    subgraph LAYER1["Layer 1: RBAC (Role Hierarchy)"]
        direction LR
        R1["CI/CD Roles<br/>control WHERE<br/>you can deploy"]
        R2["Business Roles<br/>control WHAT<br/>you can query"]
    end

    subgraph LAYER2["Layer 2: Environment Isolation (Database Grants)"]
        direction LR
        E1["DEV deployer<br/>→ *_DEV only"]
        E2["STG deployer<br/>→ *_STG only"]
        E3["PROD deployer<br/>→ *_PROD only"]
        E4["Business roles<br/>→ PROD read only"]
    end

    subgraph LAYER3["Layer 3: Row Access Policies"]
        direction LR
        RAP1["RAP_UR_REGION<br/>Fleet Mgr: ALL regions<br/>Regional Dir: SOUTHWEST<br/>Branch Mgr: BR-01024"]
        RAP2["RAP_UR_CUSTOMER<br/>Internal: ALL types<br/>External: CONSTRUCTION,<br/>INFRASTRUCTURE, GOV only"]
    end

    subgraph LAYER4["Layer 4: Column Masking"]
        direction LR
        M1["Customer PII<br/>Fleet Mgr: Full<br/>Analyst: Partial<br/>External: Redacted"]
        M2["Pricing<br/>Internal: Visible<br/>External: NULL"]
        M3["Credit Limits<br/>Fleet Mgr: Visible<br/>All others: NULL"]
    end

    subgraph LAYER5["Layer 5: Audit Trail"]
        direction LR
        A1["PROMOTION_LOG<br/>who deployed what,<br/>where, when"]
        A2["ACCESS_HISTORY<br/>who queried what,<br/>when"]
        A3["CLONE_REGISTRY<br/>who cloned what,<br/>TTL tracking"]
    end

    LAYER1 --> LAYER2
    LAYER2 --> LAYER3
    LAYER3 --> LAYER4
    LAYER4 --> LAYER5

    style LAYER1 fill:#e2d9f3,stroke:#6610f2,color:#3d0a70
    style LAYER2 fill:#d1e7dd,stroke:#198754,color:#0f5132
    style LAYER3 fill:#fff3cd,stroke:#ffc107,color:#664d03
    style LAYER4 fill:#f8d7da,stroke:#dc3545,color:#842029
    style LAYER5 fill:#cff4fc,stroke:#0dcaf0,color:#055160
```

---

## 8. UR Migration Path: 3 Accounts → 1 Account

Shows how UR's current fragmented architecture maps to the target Container-by-DB model — with CI/CD RBAC replacing account-level isolation.

```mermaid
flowchart LR
    subgraph CURRENT["Current State: 3 Accounts"]
        direction TB
        ACC1["EDW PRODUCTION<br/>Account<br/><i>Local Auth</i><br/><i>Wherescape Red</i>"]
        ACC2["EDW DEVELOPMENT<br/>Account<br/><i>Mirror of Prod</i>"]
        ACC3["DISCOVERY<br/>Account<br/><i>SSO + Cortex AI</i>"]
        ACC1 ---|"Manual<br/>data copy"| ACC2
        ACC1 ---|"Read-only<br/>share"| ACC3
    end

    CURRENT ==>|"Consolidate"| TARGET

    subgraph TARGET["Target State: 1 Account, Container-by-DB"]
        direction TB

        subgraph ROLES["CI/CD RBAC Replaces Account Boundaries"]
            direction LR
            DP["UR_CICD_DEPLOY_PROD<br/>replaces PROD account wall"]:::prodRole
            DS["UR_CICD_DEPLOY_STG<br/>replaces manual QA"]:::stgRole
            DD["UR_CICD_DEPLOY_DEV<br/>replaces DEV account wall"]:::devRole
        end

        subgraph ENVS["Environment Databases"]
            direction LR
            TDEV["*_DEV<br/>(was: EDW Dev Account)"]:::devDb
            TSTG["*_STG<br/>(new: automated gates)"]:::stgDb
            TPROD["*_PROD<br/>(was: EDW Prod Account)"]:::prodDb
        end

        subgraph AI["Cortex AI"]
            direction LR
            TAI["Semantic Views + Cortex Analyst<br/>(was: Discovery Account)"]:::aiDb
        end

        ROLES --> ENVS
        ENVS --> AI
    end

    classDef prodRole fill:#dc3545,color:#fff
    classDef stgRole fill:#fd7e14,color:#fff
    classDef devRole fill:#198754,color:#fff
    classDef devDb fill:#d1e7dd,stroke:#198754,color:#0f5132
    classDef stgDb fill:#fff3cd,stroke:#fd7e14,color:#664d03
    classDef prodDb fill:#f8d7da,stroke:#dc3545,color:#842029
    classDef aiDb fill:#e2d9f3,stroke:#6610f2,color:#3d0a70

    style CURRENT fill:#f8f9fa,stroke:#dc3545,stroke-width:2px,stroke-dasharray: 5 5,color:#212529
    style TARGET fill:#f8f9fa,stroke:#198754,stroke-width:2px,color:#212529
    style ROLES fill:#f0f0f0,stroke:#6610f2,color:#212529
    style ENVS fill:#f0f0f0,stroke:#0d6efd,color:#212529
    style AI fill:#f0f0f0,stroke:#6610f2,color:#212529
```

---

## 9. GitHub Actions → Snowflake Role Mapping

Shows how each GitHub Actions job maps to a specific Snowflake CI/CD role and target environment. The workflow file is the orchestrator; the Snowflake role is the enforcer.

```mermaid
flowchart TD
    subgraph GHA["GitHub Actions: ur-snowflake-cicd.yml"]
        direction TB

        subgraph TRIGGERS["Triggers"]
            direction LR
            T1["PR to develop"]
            T2["Push to develop"]
            T3["Push to main"]
        end

        LINT["lint<br/><i>No Snowflake connection</i><br/>sqlfluff --dialect snowflake"]:::offlineJob

        VALIDATE["validate<br/><b>UR_CICD_VALIDATOR</b><br/>sf_validate.py"]:::valJob

        subgraph DEPLOY_JOBS["Deploy Jobs (mutually exclusive)"]
            direction LR
            DEV_JOB["deploy-dev<br/><b>UR_CICD_DEPLOY_DEV</b><br/>sf_deploy.py + smoke tests"]:::devJob
            STG_JOB["deploy-stg<br/><b>UR_CICD_DEPLOY_STG</b><br/>sf_deploy.py + full tests"]:::stgJob
            PROD_JOB["deploy-prod<br/><b>UR_CICD_DEPLOY_PROD</b><br/>sf_deploy.py + audit log<br/><i>GitHub Env: production</i>"]:::prodJob
        end

        TRIGGERS --> LINT
        LINT --> VALIDATE
        VALIDATE --> DEPLOY_JOBS

        T1 -.->|"activates"| DEV_JOB
        T2 -.->|"activates"| STG_JOB
        T3 -.->|"activates"| PROD_JOB
    end

    subgraph SF["Snowflake Account"]
        direction LR
        DEV_DB["*_DEV<br/>databases"]:::devDb
        STG_DB["*_STG<br/>databases"]:::stgDb
        PROD_DB["*_PROD<br/>databases"]:::prodDb
        GOV_DB["GOVERNANCE<br/>ENVIRONMENT_REGISTRY<br/>PROMOTION_LOG"]:::govDb
    end

    DEV_JOB -->|"ALL DDL"| DEV_DB
    STG_JOB -->|"ALL DDL"| STG_DB
    PROD_JOB -->|"ALL DDL"| PROD_DB
    VALIDATE -->|"SELECT"| GOV_DB

    classDef offlineJob fill:#6c757d,color:#fff,stroke:#495057
    classDef valJob fill:#0dcaf0,color:#000,stroke:#0aa2c0
    classDef devJob fill:#198754,color:#fff,stroke:#146c43
    classDef stgJob fill:#fd7e14,color:#fff,stroke:#ca6510
    classDef prodJob fill:#dc3545,color:#fff,stroke:#b02a37
    classDef devDb fill:#d1e7dd,stroke:#198754,color:#0f5132
    classDef stgDb fill:#fff3cd,stroke:#fd7e14,color:#664d03
    classDef prodDb fill:#f8d7da,stroke:#dc3545,color:#842029
    classDef govDb fill:#cff4fc,stroke:#0dcaf0,color:#055160

    style GHA fill:#f8f9fa,stroke:#0d6efd,stroke-width:2px,color:#212529
    style TRIGGERS fill:#e2e3e5,stroke:#6c757d,color:#212529
    style DEPLOY_JOBS fill:#f0f0f0,stroke:#6c757d,color:#212529
    style SF fill:#f8f9fa,stroke:#dee2e6,color:#212529
```

---

## 10. Python Tooling → Stored Procedure Call Chain

Shows how the three Python CI/CD scripts call Snowflake stored procedures and tables. Every tool queries `ENVIRONMENT_REGISTRY` first — no hardcoded database names.

```mermaid
flowchart LR
    subgraph TOOLS["Python CI/CD Tools"]
        direction TB
        DEPLOY["sf_deploy.py<br/><i>--action deploy</i>"]:::toolNode
        VALIDATE["sf_validate.py<br/><i>--target-env PROD</i>"]:::toolNode
        TESTS["sf_integration_tests.py<br/><i>--suite full</i>"]:::toolNode
    end

    subgraph REGISTRY["ENVIRONMENT_REGISTRY"]
        direction TB
        REG["SELECT DATABASE_NAME,<br/>DEPLOY_ROLE<br/>WHERE ENV = target"]:::registryNode
    end

    subgraph PROCS["Stored Procedures"]
        direction TB
        VP["VALIDATE_PROMOTION<br/>(source_db, target_env, schema)"]:::procNode
        PO["PROMOTE_OBJECT<br/>(type, source, target, method)"]:::procNode
        PC["PROVISION_DEV_CLONE<br/>(team, role, ttl)"]:::procNode
        CC["CLEANUP_EXPIRED_CLONES"]:::procNode
    end

    subgraph AUDIT["Audit Tables"]
        direction TB
        PL["PROMOTION_LOG"]:::auditNode
        CR["CLONE_REGISTRY"]:::auditNode
    end

    DEPLOY -->|"1. resolve target"| REG
    VALIDATE -->|"1. resolve target"| REG
    TESTS -->|"1. resolve target"| REG

    DEPLOY -->|"2. execute SQL"| TARGET_DB["Target Database<br/>(resolved from registry)"]
    DEPLOY -->|"3. log result"| PL
    DEPLOY -->|"or call"| PO

    VALIDATE -->|"2. call"| VP
    VP -->|"reads"| REG

    PO -->|"writes"| PL
    PC -->|"writes"| CR
    CC -->|"reads + updates"| CR

    classDef toolNode fill:#0d6efd,color:#fff,stroke:#0a58ca
    classDef registryNode fill:#ffc107,color:#000,stroke:#cc9a06
    classDef procNode fill:#6610f2,color:#fff,stroke:#520dc2
    classDef auditNode fill:#0dcaf0,color:#000,stroke:#0aa2c0

    style TOOLS fill:#f8f9fa,stroke:#0d6efd,color:#212529
    style REGISTRY fill:#fff3cd,stroke:#ffc107,color:#212529
    style PROCS fill:#e2d9f3,stroke:#6610f2,color:#212529
    style AUDIT fill:#cff4fc,stroke:#0dcaf0,color:#212529
```
