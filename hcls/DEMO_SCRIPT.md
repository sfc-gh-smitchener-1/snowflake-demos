# HCLS Demo Script — 15 Minute Walkthrough

## Overview

Structured 15-minute demonstration of the Knowledge Graph solving HCLS-specific challenges: PHI governance, patient entity resolution, HIPAA compliance scoring, and clinical care pathway analysis.

## Prerequisites

1. Core DCA demo deployed (scripts 01-15)
2. FHIR data generated and loaded
3. HCLS graph extensions deployed:
   ```sql
   @demos/hcls/sql/01_hcls_graph_populate.sql
   @demos/hcls/sql/02_hcls_hipaa_gaps.sql
   @demos/hcls/sql/03_hcls_rai_inference.sql
   ```
4. Streamlit app deployed with Page 6 (Knowledge Graph)

## Demo Flow

### Opening (1 min)

Talk Track:
> "Healthcare data carries the strongest regulatory requirements of any industry. Today I'll show you how a Knowledge Graph — powered by RelationalAI on Snowflake — automatically detects HIPAA compliance gaps, resolves patient identities across systems, and provides continuous governance scoring. No manual audits required."

### Part 1: The Clinical Knowledge Graph (3 min)

Show the graph structure:
```sql
USE ROLE ONTOLOGY_ADMIN;
-- Clinical node distribution
SELECT node_type, source_system, COUNT(*) AS cnt
FROM DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_NODES
WHERE source_system = 'FHIR' OR layer = 'METADATA'
GROUP BY node_type, source_system
ORDER BY cnt DESC;
```

> "We have [X] clinical nodes — patients, encounters, conditions, medications — linked to [Y] metadata nodes representing the actual Snowflake objects that store them. The graph connects the clinical world to the technical world."

Show a Patient 360:
```sql
-- All relationships for a single patient
SELECT e.edge_type, n2.node_type, n2.display_name, n2.source_system
FROM DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_EDGES e
JOIN DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_NODES n ON e.source_node_id = n.node_id
JOIN DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_NODES n2 ON e.target_node_id = n2.node_id
WHERE n.node_type = 'PATIENT'
LIMIT 1;
-- (Expand with specific patient lookup)
```

> "One graph query gives us the complete patient picture: encounters, diagnoses, medications, practitioners — all linked."

### Part 2: PHI Detection — RAI Finds Unclassified PHI (3 min)

```sql
-- PHI propagation recommendations
SELECT severity, description, suggested_action
FROM DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_RAI_RECOMMENDATIONS
WHERE recommendation_type = 'PII_PROPAGATION'
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
```

> "RAI traced data lineage and found columns receiving patient data from PHI-tagged sources — but the receiving columns have no HIPAA classification. These are your compliance blind spots. Without the graph, you'd need a manual audit to find them."

### Part 3: Patient Entity Resolution (3 min)

```sql
-- Cross-system patient matches
SELECT c.cluster_id, c.cluster_label, c.confidence,
       n.display_name, n.source_system, n.node_type
FROM DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_RAI_ENTITY_CLUSTERS c
JOIN DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_NODES n ON c.node_id = n.node_id
WHERE n.node_type IN ('PATIENT', 'EMPLOYEE')
  AND c.confidence > 0.8
ORDER BY c.cluster_id, c.confidence DESC;
```

> "RAI resolved patients across FHIR and Workday using name and demographic similarity. Cluster 1 shows the same person appearing in both systems — no external MPI needed."

### Part 4: HIPAA Compliance Scores (3 min)

```sql
-- HIPAA governance scores for clinical objects
SELECT n.display_name, n.node_type,
       ROUND(s.overall_score, 2) AS hipaa_score,
       ROUND(s.tag_coverage, 2) AS classification,
       ROUND(s.ownership_score, 2) AS ownership
FROM DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_RAI_GOVERNANCE_SCORES s
JOIN DCA_DEMO.GOVERNANCE.ONTOLOGY_GRAPH_NODES n ON s.node_id = n.node_id
WHERE n.source_system IN ('FHIR', 'SNOWFLAKE')
ORDER BY s.overall_score ASC
LIMIT 10;
```

> "Every object gets a HIPAA governance score from 0 to 1. Scores below 0.4 need immediate attention. This replaces your annual manual assessment with continuous, automated scoring."

### Part 5: Streamlit Visualization (2 min)

Navigate to Page 6: Knowledge Graph
- Filter: Source System = FHIR, Layer = BUSINESS
- Show clinical graph with patient-centered view
- Switch to Governance Scores tab — filter to scores < 0.4
- Show Recommendations tab — HIPAA-specific recommendations

> "The privacy officer can see compliance posture in real-time. No more waiting for the annual audit to discover gaps."

### Closing (1 min)

> "To summarize:
> 1. The Knowledge Graph connects clinical data to governance metadata
> 2. RAI automatically detects PHI propagation that manual audits miss
> 3. Patient identity resolution works across systems without an MPI
> 4. Continuous HIPAA scoring replaces annual manual assessments
> 5. All of this runs natively in Snowflake — RAI on SPCS, no external tools"

## Common Questions

**Q: How accurate is the entity resolution?**
> "Configurable confidence threshold. Default 0.7 Jaccard similarity on name tokens + exact DOB match. In production, you'd add MRN cross-references where available."

**Q: Can this satisfy an OCR audit?**
> "The governance scores, recommendation history, and access edges provide documentary evidence of continuous compliance monitoring — stronger than point-in-time manual audits."

**Q: What about de-identification for research?**
> "The graph tracks DE_IDENTIFIED_FROM edges. If a research dataset was derived from PHI, the provenance is recorded and auditable."

**Q: Does this replace our existing HIPAA tools?**
> "It complements them. The graph integrates with GRC platforms (export scores to ServiceNow/Archer) and provides the data-layer evidence that compliance tools need."
