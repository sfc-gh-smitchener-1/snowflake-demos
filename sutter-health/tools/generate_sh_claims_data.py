#!/usr/bin/env python3
"""
Sutter Health Claims Data Generator

Generates realistic synthetic healthcare claims data for the Sutter Health DCA demo:
  - member_enrollment:      1,000 members with risk scores, demographics, plan info
  - provider_directory:       200 credentialed providers with network status
  - raw_claims:            ~12,000 claim lines (avg 12/member over last 12 months)
  - risk_adjustment_flags: ~3,500 HCC flags (pre-seeded historical)
  - claims_summary:         1,000 member-level rollups

Usage:
    python generate_sh_claims_data.py --output ../data
    python generate_sh_claims_data.py --output ../data --quick       # 10% sample
    python generate_sh_claims_data.py --output ../data --scale 2.0   # Double size
"""

import os
import sys
import random
import hashlib
import csv
import argparse
import uuid
from datetime import datetime, timedelta, date
from typing import List, Dict, Any, Optional
from decimal import Decimal

# Import base generator infrastructure from the core data_generator
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..', 'tools'))
from data_generator import SourceSystemGenerator, save_to_csv as base_save_to_csv

try:
    from faker import Faker
except ImportError:
    print("ERROR: Faker not installed. Run: pip install faker")
    sys.exit(1)


# ============================================================================
# REFERENCE DATA — ICD-10 / HCC mappings
# ============================================================================

HCC_CODES = [
    # (icd10_prefix, hcc_code, hcc_description, risk_weight, clinical_category)
    ('E10', 'HCC17', 'Diabetes with Acute Complications',        0.368, 'DIABETES'),
    ('E11', 'HCC19', 'Diabetes without Complication',            0.118, 'DIABETES'),
    ('E13', 'HCC18', 'Diabetes with Chronic Complications',      0.302, 'DIABETES'),
    ('I21', 'HCC86', 'Acute Myocardial Infarction',              0.365, 'CARDIAC'),
    ('I50', 'HCC85', 'Congestive Heart Failure',                 0.331, 'CARDIAC'),
    ('I48', 'HCC96', 'Specified Heart Arrhythmias',              0.271, 'CARDIAC'),
    ('I25', 'HCC88', 'Angina Pectoris / Old MI',                 0.241, 'CARDIAC'),
    ('J44', 'HCC111','COPD',                                     0.335, 'RESPIRATORY'),
    ('J43', 'HCC112','Fibrosis of Lung',                         0.199, 'RESPIRATORY'),
    ('N18', 'HCC136','Chronic Kidney Disease Stage 4',           0.237, 'RENAL'),
    ('N17', 'HCC135','Acute Renal Failure',                      0.441, 'RENAL'),
    ('C34', 'HCC9',  'Lung and Other Severe Cancers',            2.422, 'ONCOLOGY'),
    ('C50', 'HCC12', 'Breast Cancer',                            0.664, 'ONCOLOGY'),
    ('C18', 'HCC12', 'Colon Cancer',                             0.664, 'ONCOLOGY'),
    ('F20', 'HCC57', 'Schizophrenia',                            0.620, 'BEHAVIORAL_HEALTH'),
    ('F31', 'HCC58', 'Major Depressive/Bipolar Disorders',       0.395, 'BEHAVIORAL_HEALTH'),
    ('M80', 'HCC168','Hip Fracture/Dislocation',                 0.489, 'MUSCULOSKELETAL'),
    ('M16', 'HCC40', 'Rheumatoid Arthritis',                     0.421, 'MUSCULOSKELETAL'),
]

# ICD-10 codes with subcodes for realistic generation
ICD10_BY_PREFIX = {
    'E10': ['E10.10', 'E10.40', 'E10.65', 'E10.9'],
    'E11': ['E11.00', 'E11.21', 'E11.40', 'E11.65', 'E11.9'],
    'E13': ['E13.10', 'E13.40', 'E13.65'],
    'I21': ['I21.09', 'I21.19', 'I21.29', 'I21.3'],
    'I50': ['I50.20', 'I50.22', 'I50.32', 'I50.42'],
    'I48': ['I48.0', 'I48.11', 'I48.19', 'I48.20'],
    'I25': ['I25.10', 'I25.110', 'I25.2', 'I25.5'],
    'J44': ['J44.0', 'J44.1', 'J44.9'],
    'J43': ['J43.0', 'J43.1', 'J43.9'],
    'N18': ['N18.4', 'N18.5', 'N18.6'],
    'N17': ['N17.0', 'N17.2', 'N17.9'],
    'C34': ['C34.10', 'C34.11', 'C34.12', 'C34.30'],
    'C50': ['C50.011', 'C50.019', 'C50.211', 'C50.411'],
    'C18': ['C18.0', 'C18.2', 'C18.4', 'C18.7'],
    'F20': ['F20.0', 'F20.1', 'F20.5', 'F20.9'],
    'F31': ['F31.10', 'F31.30', 'F31.62', 'F31.9'],
    'M80': ['M80.011A', 'M80.019A', 'M80.811A'],
    'M16': ['M16.0', 'M16.10', 'M16.30'],
}

# Low-risk ICD-10 codes for non-HCC claims
ROUTINE_ICD10 = [
    'Z00.00',  # Encounter for general adult medical examination
    'Z00.01',  # Encounter for general adult medical examination with abnormal findings
    'Z23',     # Encounter for immunization
    'J06.9',   # Acute upper respiratory infection
    'M54.5',   # Low back pain
    'K21.0',   # GERD with esophagitis
    'I10',     # Essential hypertension
    'Z79.01',  # Long-term use of anticoagulants
    'H52.4',   # Presbyopia
    'K57.30',  # Diverticulosis
]

CPT_CODES = {
    'PROFESSIONAL': ['99213', '99214', '99215', '99203', '99204', '99205', '99241', '99243',
                     '93000', '93005', '71046', '80053', '85025', '87491'],
    'INSTITUTIONAL': ['99231', '99232', '99233', '99291', '99292'],
    'PHARMACY': ['J3490', 'J7999', 'S0014'],
    'DENTAL': ['D0120', 'D0210', 'D1110'],
}

PLAN_TYPES = ['HMO', 'PPO', 'POS', 'HDHP', 'MEDICARE_ADVANTAGE', 'MEDICAID_MANAGED']
PLAN_WEIGHTS = [0.20, 0.25, 0.10, 0.15, 0.20, 0.10]

PRODUCT_LINES = {
    'HMO': 'COMMERCIAL', 'PPO': 'COMMERCIAL', 'POS': 'COMMERCIAL', 'HDHP': 'COMMERCIAL',
    'MEDICARE_ADVANTAGE': 'MEDICARE', 'MEDICAID_MANAGED': 'MEDICAID',
}

CALIFORNIA_ZIPS = [
    '94102', '94103', '94115', '94118', '94121', '94122', '94123', '94131', '94132',
    '95014', '95054', '95126', '95128', '95131', '95148',
    '94501', '94577', '94578', '94603', '94609',
    '93701', '93711', '93720', '93722', '93727',
]

CALIFORNIA_COUNTIES = {
    '94': ('06075', 'CA'),  # San Francisco
    '95': ('06085', 'CA'),  # Santa Clara
    '945': ('06001', 'CA'), # Alameda
    '936': ('06019', 'CA'), # Fresno
}

SPECIALTY_CODES = [
    ('01', 'Internal Medicine',        'Internal Medicine / General Practice', False),
    ('08', 'Geriatric Medicine',       'Geriatrics',                           False),
    ('11', 'Oncology',                 'Medical Oncology',                     False),
    ('24', 'Family Practice',          'Family Practice',                      True),
    ('38', 'Geriatric Psychiatry',     'Psychiatry',                           False),
    ('66', 'Rheumatology',             'Rheumatology',                         False),
    ('78', 'Cardiology',               'Cardiovascular Disease',               False),
    ('86', 'Pulmonology',              'Pulmonary Disease',                     False),
    ('90', 'Nephrology',               'Nephrology',                           False),
    ('97', 'Primary Care',             'General Practice',                     True),
]

DENIAL_REASONS = [
    ('CO-4',  'The procedure code is inconsistent with the modifier'),
    ('CO-45', 'Charges exceed contracted fee arrangement'),
    ('CO-50', 'Non-covered services'),
    ('CO-96', 'Non-covered charge(s)'),
    ('CO-97', 'Benefit maximum reached'),
    ('CO-197','Precertification/authorization absent'),
    ('PR-1',  'Deductible amount'),
    ('PR-2',  'Coinsurance amount'),
]

PLACE_OF_SERVICE = [
    ('11', 'Office',               0.45),
    ('21', 'Inpatient Hospital',   0.10),
    ('22', 'Outpatient Hospital',  0.18),
    ('23', 'Emergency Room',       0.08),
    ('31', 'Skilled Nursing',      0.04),
    ('49', 'Independent Clinic',   0.06),
    ('71', 'Public Health Clinic', 0.03),
    ('02', 'Telehealth',           0.06),
]

FLAG_SOURCES = [('CLAIMS', 0.65), ('ENCOUNTER', 0.15), ('CHART_REVIEW', 0.12), ('PROSPECTIVE', 0.08)]
FLAG_STATUSES = [('ACTIVE', 0.80), ('VALIDATED', 0.15), ('SUPERSEDED', 0.05)]

GROUP_NAMES = [
    'Sutter Medical Foundation', 'Palo Alto Medical Foundation', 'UCSF Health Partners',
    'Bay Area Health Alliance', 'Central Valley Employers Group', 'NorCal Tech Coalition',
    'California State Employees', 'Safeway Health Plan', 'Kaiser Community Partners',
]

RISK_CATEGORIES = [
    ('LOW',        0.30, 0.3, 0.9),
    ('MODERATE',   0.35, 0.9, 1.8),
    ('HIGH',       0.22, 1.8, 2.8),
    ('VERY_HIGH',  0.10, 2.8, 4.0),
    ('CATASTROPHIC',0.03, 4.0, 8.5),
]


# ============================================================================
# MAIN GENERATOR
# ============================================================================

class SutterHealthClaimsGenerator(SourceSystemGenerator):
    SYSTEM_NAME = 'SUTTER_HEALTH_CLAIMS'

    DEFAULT_COUNTS = {
        'members': 1000,
        'providers': 200,
        'claims_per_member': 12,   # avg claims per member per year
    }

    def __init__(self, seed: int = 42):
        super().__init__(seed=seed)
        self.fake = Faker(['en_US'])
        Faker.seed(seed)
        random.seed(seed)

    def generate(self, counts: Dict[str, int]) -> Dict[str, List[Dict]]:
        n_members = counts.get('members', self.DEFAULT_COUNTS['members'])
        n_providers = counts.get('providers', self.DEFAULT_COUNTS['providers'])
        claims_per_member = counts.get('claims_per_member', self.DEFAULT_COUNTS['claims_per_member'])

        print(f"Generating {n_members} members, {n_providers} providers, ~{n_members * claims_per_member} claims...")

        members   = self._generate_members(n_members)
        providers = self._generate_providers(n_providers)
        claims    = self._generate_claims(members, providers, claims_per_member)
        flags     = self._generate_risk_flags(members, claims)
        summary   = self._generate_claims_summary(members, claims, flags)

        return {
            'member_enrollment':     members,
            'provider_directory':    providers,
            'raw_claims':            claims,
            'risk_adjustment_flags': flags,
            'claims_summary':        summary,
        }

    # ──────────────────────────────────────────────────────────────────────
    # Members
    # ──────────────────────────────────────────────────────────────────────

    def _generate_members(self, n: int) -> List[Dict]:
        members = []
        today = date.today()

        for i in range(n):
            member_id    = str(uuid.uuid5(uuid.NAMESPACE_OID, f'SH_MBR_{i}'))
            subscriber_id = f'SH{100000 + i}'

            # Age distribution: skew older (health plan demographic)
            age = random.choices(
                [random.randint(0,17), random.randint(18,34), random.randint(35,49),
                 random.randint(50,64), random.randint(65,89)],
                weights=[0.08, 0.12, 0.20, 0.30, 0.30]
            )[0]
            dob = today - timedelta(days=age * 365 + random.randint(0, 364))
            gender = random.choices(['M', 'F'], weights=[0.47, 0.53])[0]

            plan_type = random.choices(PLAN_TYPES, weights=PLAN_WEIGHTS)[0]
            product_line = PRODUCT_LINES[plan_type]

            # Risk category — older members skew higher risk
            risk_weights = [0.40, 0.35, 0.15, 0.07, 0.03] if age < 50 else [0.15, 0.30, 0.30, 0.18, 0.07]
            risk_cat_info = random.choices(RISK_CATEGORIES, weights=risk_weights)[0]
            risk_category, _, risk_min, risk_max = risk_cat_info
            risk_score = round(random.uniform(risk_min, risk_max), 4)
            prior_risk  = round(risk_score * random.uniform(0.85, 1.15), 4)
            risk_pct    = min(99, max(1, int((risk_score / 8.5) * 100) + random.randint(-5, 5)))

            zip_code = random.choice(CALIFORNIA_ZIPS)
            prefix = zip_code[:3]
            county_code, state_code = CALIFORNIA_COUNTIES.get(prefix,
                                        CALIFORNIA_COUNTIES.get(zip_code[:2], ('06085', 'CA')))

            coverage_start = today - timedelta(days=random.randint(90, 1460))
            enrollment_status = random.choices(
                ['ACTIVE', 'TERMED', 'COBRA', 'PENDING'],
                weights=[0.82, 0.10, 0.05, 0.03]
            )[0]
            coverage_end = None
            if enrollment_status == 'TERMED':
                coverage_end = coverage_start + timedelta(days=random.randint(30, 730))
            elif enrollment_status == 'COBRA':
                coverage_end = today + timedelta(days=random.randint(30, 180))

            group_number = f'GRP{10000 + random.randint(0, 500)}'
            employer_name = random.choice(GROUP_NAMES)

            # PCP assignment
            pcp_npi = f'1{random.randint(100000000, 999999999)}'

            # Medicare Advantage gets MBI
            mbi = None
            if plan_type == 'MEDICARE_ADVANTAGE':
                mbi = self._generate_mbi()

            chronic_count = random.choices([0, 1, 2, 3, 4, 5],
                weights=[0.20, 0.25, 0.22, 0.18, 0.10, 0.05])[0]

            care_mgmt = risk_category in ('HIGH', 'VERY_HIGH', 'CATASTROPHIC') and random.random() < 0.60

            record = {
                'MEMBER_ID': member_id,
                'SUBSCRIBER_ID': subscriber_id,
                'MBI_NUMBER': mbi,
                'MEDICAID_ID': f'CA{random.randint(1000000000, 9999999999)}' if plan_type == 'MEDICAID_MANAGED' else None,
                'MEMBER_RELATIONSHIP': random.choices(['SELF', 'SPOUSE', 'DEPENDENT'],
                                                       weights=[0.55, 0.25, 0.20])[0],
                'PLAN_ID': f'{plan_type[:3]}-2024-{random.randint(1,9):02d}',
                'PLAN_NAME': f'Sutter Health {plan_type.replace("_"," ").title()} Gold',
                'PLAN_TYPE': plan_type,
                'PRODUCT_LINE': product_line,
                'GROUP_NUMBER': group_number,
                'EMPLOYER_NAME': employer_name,
                'DATE_OF_BIRTH': dob.isoformat(),
                'GENDER': gender,
                'ZIP_CODE': zip_code,
                'COUNTY_CODE': county_code,
                'STATE_CODE': state_code,
                'COVERAGE_START_DATE': coverage_start.isoformat(),
                'COVERAGE_END_DATE': coverage_end.isoformat() if coverage_end else None,
                'ENROLLMENT_STATUS': enrollment_status,
                'COBRA_FLAG': str(enrollment_status == 'COBRA').upper(),
                'DUAL_ELIGIBLE': str(plan_type == 'MEDICAID_MANAGED' and age >= 65 and random.random() < 0.20).upper(),
                'LIS_LEVEL': random.choice(['LIS1', 'LIS2', 'LIS3', None]) if plan_type == 'MEDICARE_ADVANTAGE' else None,
                'RISK_SCORE': risk_score,
                'PRIOR_YEAR_RISK_SCORE': prior_risk,
                'RISK_CATEGORY': risk_category,
                'RISK_PERCENTILE': risk_pct,
                'PROSPECTIVE_RISK_SCORE': round(risk_score * random.uniform(0.90, 1.20), 4),
                'CARE_MANAGEMENT_FLAG': str(care_mgmt).upper(),
                'CHRONIC_CONDITION_COUNT': chronic_count,
                'PRIMARY_CARE_NPI': pcp_npi,
                '_SOURCE_SYSTEM': 'ELIGIBILITY_834',
                '_VALID_FROM': (today - timedelta(days=random.randint(0, 30))).strftime('%Y-%m-%d %H:%M:%S'),
                '_VALID_TO': None,
                '_IS_CURRENT': 'TRUE',
                '_LOADED_AT': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                '_RECORD_HASH': self._hash(member_id, str(risk_score), enrollment_status),
            }
            members.append(record)

        print(f"  ✓ {len(members)} members")
        return members

    # ──────────────────────────────────────────────────────────────────────
    # Providers
    # ──────────────────────────────────────────────────────────────────────

    def _generate_providers(self, n: int) -> List[Dict]:
        providers = []
        used_npis = set()

        for i in range(n):
            while True:
                npi = f'1{random.randint(100000000, 999999999)}'
                if npi not in used_npis:
                    used_npis.add(npi)
                    break

            spec = random.choice(SPECIALTY_CODES)
            spec_code, spec_short, spec_desc, is_pcp = spec

            network_status = random.choices(
                ['IN_NETWORK', 'PREFERRED', 'OUT_OF_NETWORK'],
                weights=[0.70, 0.20, 0.10]
            )[0]

            quality_tier = random.choices(['TIER_1', 'TIER_2', 'TIER_3'],
                                          weights=[0.30, 0.50, 0.20])[0]
            board_cert   = random.random() < (0.85 if quality_tier == 'TIER_1' else 0.60)
            malpractice  = random.random() < 0.03

            cred_status  = 'ACTIVE' if random.random() < 0.92 else random.choice(['PENDING', 'SUSPENDED', 'EXPIRED'])
            cred_expiry  = date.today() + timedelta(days=random.randint(30, 730))

            zip_code = random.choice(CALIFORNIA_ZIPS)
            lat  = round(37.3 + random.uniform(-0.5, 0.5), 7)
            lon  = round(-122.0 + random.uniform(-0.5, 0.5), 7)

            providers.append({
                'PROVIDER_NPI': npi,
                'GROUP_NPI': f'2{random.randint(100000000, 999999999)}' if random.random() < 0.70 else None,
                'TIN': f'{random.randint(200000000, 999999999)}',
                'PROVIDER_LAST_NAME': self.fake.last_name(),
                'PROVIDER_FIRST_NAME': self.fake.first_name(),
                'PROVIDER_CREDENTIAL': random.choices(['MD', 'DO', 'NP', 'PA', 'DDS'],
                                                       weights=[0.55, 0.15, 0.15, 0.10, 0.05])[0],
                'SPECIALTY_CODE': spec_code,
                'SPECIALTY_DESC': spec_desc,
                'TAXONOMY_CODE': f'{random.randint(100000000, 999999999)}X',
                'PRIMARY_CARE_FLAG': str(is_pcp).upper(),
                'NETWORK_STATUS': network_status,
                'NETWORK_EFFECTIVE_DATE': (date.today() - timedelta(days=random.randint(180, 1800))).isoformat(),
                'NETWORK_TERM_DATE': None,
                'ACCEPTING_NEW_PATIENTS': str(random.random() < 0.75).upper(),
                'TELEHEALTH_ENABLED': str(random.random() < 0.60).upper(),
                'QUALITY_TIER': quality_tier,
                'PRACTICE_ADDRESS_LINE1': self.fake.street_address(),
                'PRACTICE_CITY': random.choice(['San Francisco', 'San Jose', 'Oakland', 'Fresno', 'Sacramento']),
                'PRACTICE_STATE': 'CA',
                'PRACTICE_ZIP': zip_code,
                'PRACTICE_COUNTY_CODE': '06085',
                'PRACTICE_LATITUDE': lat,
                'PRACTICE_LONGITUDE': lon,
                'PRACTICE_PHONE': self.fake.numerify('###-###-####'),
                'CREDENTIAL_STATUS': cred_status,
                'CREDENTIAL_EXPIRY_DATE': cred_expiry.isoformat(),
                'BOARD_CERTIFIED': str(board_cert).upper(),
                'MALPRACTICE_FLAG': str(malpractice).upper(),
                'CLAIM_VOLUME_30D': random.randint(5, 250),
                'RISK_FLAG_VOLUME_30D': random.randint(0, 40),
                'AVG_RISK_SCORE_PANEL': round(random.uniform(0.5, 2.8), 4),
                '_SOURCE_SYSTEM': 'CAQH_PROVIEW',
                '_LOADED_AT': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                '_RECORD_HASH': self._hash(npi, spec_code, network_status),
            })

        print(f"  ✓ {len(providers)} providers")
        return providers

    # ──────────────────────────────────────────────────────────────────────
    # Claims
    # ──────────────────────────────────────────────────────────────────────

    def _generate_claims(self, members: List[Dict], providers: List[Dict],
                         avg_claims_per_member: int) -> List[Dict]:
        claims = []
        today = date.today()
        provider_npis = [p['PROVIDER_NPI'] for p in providers]

        for member in members:
            member_id     = member['MEMBER_ID']
            risk_category = member['RISK_CATEGORY']
            plan_type     = member['PLAN_TYPE']

            # Higher-risk members generate more claims
            risk_multiplier = {
                'LOW': 0.6, 'MODERATE': 0.9, 'HIGH': 1.3,
                'VERY_HIGH': 1.8, 'CATASTROPHIC': 2.5
            }.get(risk_category, 1.0)
            n_claims = max(1, int(random.gauss(avg_claims_per_member * risk_multiplier, 3)))

            for j in range(n_claims):
                claim_id = str(uuid.uuid5(uuid.NAMESPACE_OID, f'SH_CLM_{member_id}_{j}'))
                service_date = today - timedelta(days=random.randint(1, 365))

                # ICD-10 selection: high-risk members get HCC codes
                if risk_category in ('HIGH', 'VERY_HIGH', 'CATASTROPHIC') and random.random() < 0.60:
                    hcc_entry = random.choice(HCC_CODES)
                    prefix    = hcc_entry[0]
                    dx_code   = random.choice(ICD10_BY_PREFIX.get(prefix, [prefix + '.9']))
                    dx2       = random.choice(ROUTINE_ICD10) if random.random() < 0.40 else None
                elif risk_category == 'MODERATE' and random.random() < 0.25:
                    hcc_entry = random.choice(HCC_CODES[:8])  # lower-weight HCCs only
                    prefix    = hcc_entry[0]
                    dx_code   = random.choice(ICD10_BY_PREFIX.get(prefix, [prefix + '.9']))
                    dx2       = None
                else:
                    dx_code = random.choice(ROUTINE_ICD10)
                    dx2     = random.choice(ROUTINE_ICD10) if random.random() < 0.20 else None

                claim_type = random.choices(
                    ['PROFESSIONAL', 'INSTITUTIONAL', 'PHARMACY', 'DENTAL'],
                    weights=[0.55, 0.20, 0.18, 0.07]
                )[0]

                pos_entry  = random.choices(PLACE_OF_SERVICE, weights=[p[2] for p in PLACE_OF_SERVICE])[0]
                pos_code, pos_desc, _ = pos_entry

                cpt_list   = CPT_CODES.get(claim_type, CPT_CODES['PROFESSIONAL'])
                cpt_code   = random.choice(cpt_list)

                # Billed amount by claim type
                billed_map = {
                    'PROFESSIONAL':  (80, 800),
                    'INSTITUTIONAL': (500, 25000),
                    'PHARMACY':      (15, 500),
                    'DENTAL':        (50, 400),
                }
                billed_min, billed_max = billed_map[claim_type]
                billed  = round(random.uniform(billed_min, billed_max), 2)
                allowed = round(billed * random.uniform(0.55, 0.90), 2)

                claim_status = random.choices(
                    ['PAID', 'DENIED', 'PENDING', 'ADJUSTED', 'APPEALED'],
                    weights=[0.68, 0.14, 0.10, 0.05, 0.03]
                )[0]

                denial_code, denial_desc = None, None
                if claim_status == 'DENIED':
                    dc = random.choice(DENIAL_REASONS)
                    denial_code, denial_desc = dc

                paid = round(allowed * random.uniform(0.85, 1.00), 2) if claim_status == 'PAID' else 0.0
                coinsurance = round(allowed * random.uniform(0.10, 0.20), 2) if claim_status == 'PAID' else 0.0
                copay       = round(random.choice([0, 10, 20, 30, 40, 50]), 2) if claim_status == 'PAID' else 0.0
                deductible  = round(max(0, allowed - paid - coinsurance - copay), 2)
                member_resp = round(coinsurance + copay + deductible, 2)

                network_status = random.choices(
                    ['IN_NETWORK', 'PREFERRED', 'OUT_OF_NETWORK'],
                    weights=[0.72, 0.18, 0.10]
                )[0]

                # SLA calculation — 15% breach rate
                received_ts = datetime.combine(service_date, datetime.min.time()) + \
                              timedelta(hours=random.randint(0, 23), minutes=random.randint(0, 59))
                sla_breaches = random.random() < 0.15
                if claim_status == 'PENDING':
                    processed_ts   = None
                    sla_met        = None
                    processing_hrs = None
                    sla_breach_hrs = None
                else:
                    if sla_breaches:
                        proc_hours = random.uniform(24.5, 96.0)
                    else:
                        proc_hours = random.uniform(0.5, 23.5)
                    processed_ts   = received_ts + timedelta(hours=proc_hours)
                    sla_met        = proc_hours <= 24.0
                    processing_hrs = round(proc_hours, 2)
                    sla_breach_hrs = round(proc_hours - 24.0, 2) if proc_hours > 24.0 else None

                # DRG for institutional
                drg_code = str(random.randint(1, 999)).zfill(3) if claim_type == 'INSTITUTIONAL' and random.random() < 0.60 else None

                provider_npi = random.choice(provider_npis)

                claims.append({
                    'CLAIM_ID':              claim_id,
                    'CLAIM_LINE_NUMBER':     1,
                    'MEMBER_ID':             member_id,
                    'PROVIDER_NPI':          provider_npi,
                    'CLAIM_TYPE':            claim_type,
                    'CLAIM_SUBTYPE':         random.choice(['OUTPATIENT', 'PREVENTIVE', 'SPECIALIST', 'INPATIENT', 'ER']),
                    'BILL_TYPE_CODE':        f'{random.randint(10, 85):02d}1' if claim_type == 'INSTITUTIONAL' else None,
                    'PLACE_OF_SERVICE_CODE': pos_code,
                    'PLACE_OF_SERVICE_DESC': pos_desc,
                    'PRIMARY_DX_CODE':       dx_code,
                    'SECONDARY_DX_CODE_1':   dx2,
                    'SECONDARY_DX_CODE_2':   None,
                    'PROCEDURE_CODE':        cpt_code,
                    'PROCEDURE_MODIFIER':    random.choice(['25', '59', None, None, None]),
                    'REVENUE_CODE':          f'{random.randint(100, 999)}' if claim_type == 'INSTITUTIONAL' else None,
                    'DRG_CODE':              drg_code,
                    'BILLED_AMOUNT':         billed,
                    'ALLOWED_AMOUNT':        allowed if claim_status != 'DENIED' else None,
                    'PAID_AMOUNT':           paid,
                    'MEMBER_RESPONSIBILITY': member_resp,
                    'COINSURANCE_AMOUNT':    coinsurance,
                    'COPAY_AMOUNT':          copay,
                    'DEDUCTIBLE_AMOUNT':     deductible,
                    'CLAIM_STATUS':          claim_status,
                    'DENIAL_REASON_CODE':    denial_code,
                    'DENIAL_REASON_DESC':    denial_desc,
                    'PAYER_CLAIM_CONTROL_NUM': f'SH{random.randint(10000000000, 99999999999)}',
                    'SERVICE_DATE':          service_date.isoformat(),
                    'SERVICE_DATE_END':      (service_date + timedelta(days=random.randint(1, 5))).isoformat()
                                             if claim_type == 'INSTITUTIONAL' else None,
                    'CLAIM_SUBMISSION_DATE': (service_date + timedelta(days=random.randint(1, 14))).isoformat(),
                    'ADJUDICATION_DATE':     processed_ts.date().isoformat() if processed_ts else None,
                    'PLAN_YEAR':             service_date.year,
                    'CLAIM_RECEIVED_TS':     received_ts.strftime('%Y-%m-%d %H:%M:%S'),
                    'CLAIM_PROCESSED_TS':    processed_ts.strftime('%Y-%m-%d %H:%M:%S') if processed_ts else None,
                    'SLA_TARGET_HOURS':      24,
                    'SLA_MET':               str(sla_met).upper() if sla_met is not None else None,
                    'SLA_BREACH_HOURS':      sla_breach_hrs,
                    'PROCESSING_HOURS':      processing_hrs,
                    'NETWORK_STATUS':        network_status,
                    'PRIOR_AUTH_NUMBER':     f'PA{random.randint(1000000, 9999999)}' if random.random() < 0.20 else None,
                    'REFERRAL_NUMBER':       f'REF{random.randint(1000000, 9999999)}' if random.random() < 0.15 else None,
                    '_SOURCE_SYSTEM':        'EPIC_CLARITY',
                    '_LOADED_AT':            datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                    '_RECORD_HASH':          self._hash(claim_id, str(billed), claim_status),
                })

        print(f"  ✓ {len(claims)} claims")
        return claims

    # ──────────────────────────────────────────────────────────────────────
    # Risk Adjustment Flags (historical seed)
    # ──────────────────────────────────────────────────────────────────────

    def _generate_risk_flags(self, members: List[Dict], claims: List[Dict]) -> List[Dict]:
        flags = []
        run_id = str(uuid.uuid5(uuid.NAMESPACE_OID, 'SH_SEED_RUN_001'))

        # Build claim lookup by member_id
        claims_by_member: Dict[str, List[Dict]] = {}
        for c in claims:
            claims_by_member.setdefault(c['MEMBER_ID'], []).append(c)

        today = date.today()

        for member in members:
            member_id     = member['MEMBER_ID']
            risk_category = member['RISK_CATEGORY']

            if risk_category not in ('HIGH', 'VERY_HIGH', 'CATASTROPHIC', 'MODERATE'):
                continue  # Low-risk members typically don't have HCC flags

            member_claims = claims_by_member.get(member_id, [])
            hcc_claims    = [c for c in member_claims if c['CLAIM_STATUS'] == 'PAID']

            if not hcc_claims:
                continue

            # Pick 1-4 distinct HCC categories per member
            n_flags = random.choices([1, 2, 3, 4],
                weights=[0.45, 0.30, 0.17, 0.08])[0]
            hcc_entries = random.sample(HCC_CODES, min(n_flags, len(HCC_CODES)))

            for hcc_entry in hcc_entries:
                prefix, hcc_code, hcc_desc, risk_wt, _ = hcc_entry

                # Find a claim with matching DX prefix or use any paid claim
                matching = [c for c in hcc_claims if c['PRIMARY_DX_CODE'] and c['PRIMARY_DX_CODE'].startswith(prefix)]
                source_claim = matching[0] if matching else random.choice(hcc_claims)

                icd10_code = source_claim['PRIMARY_DX_CODE'] if matching else \
                             random.choice(ICD10_BY_PREFIX.get(prefix, [prefix + '.9']))

                gender = member['GENDER']
                coeff  = round(1.02 if gender == 'M' else 1.00, 4)

                flag_source = random.choices(
                    [s for s, _ in FLAG_SOURCES],
                    weights=[w for _, w in FLAG_SOURCES]
                )[0]
                flag_status = random.choices(
                    [s for s, _ in FLAG_STATUSES],
                    weights=[w for _, w in FLAG_STATUSES]
                )[0]

                flag_date = today - timedelta(days=random.randint(1, 90))

                flags.append({
                    'FLAG_ID':               str(uuid.uuid5(uuid.NAMESPACE_OID, f'SH_FLAG_{member_id}_{hcc_code}')),
                    'MEMBER_ID':             member_id,
                    'CLAIM_ID':              source_claim['CLAIM_ID'],
                    'HCC_CODE':              hcc_code,
                    'HCC_DESCRIPTION':       hcc_desc,
                    'ICD10_CODE':            icd10_code,
                    'ICD10_DESCRIPTION':     hcc_desc,
                    'RISK_WEIGHT':           risk_wt,
                    'RISK_COEFFICIENT':      coeff,
                    'INCREMENTAL_RISK':      round(risk_wt * coeff, 4),
                    'FLAG_DATE':             flag_date.isoformat(),
                    'FLAG_SOURCE':           flag_source,
                    'FLAG_STATUS':           flag_status,
                    'VALIDATION_SOURCE':     'CODER_REVIEW' if flag_source == 'CHART_REVIEW' else None,
                    'PLAN_YEAR':             flag_date.year,
                    'CLAIM_SLA_MET':         source_claim['SLA_MET'],
                    'CLAIM_PROCESSING_HOURS': source_claim['PROCESSING_HOURS'],
                    'PIPELINE_RUN_ID':       run_id,
                    'RUN_DATE':              flag_date.isoformat(),
                    '_SOURCE_SYSTEM':        'RISK_ADJ_PIPELINE',
                    '_LOADED_AT':            datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                })

        print(f"  ✓ {len(flags)} risk adjustment flags")
        return flags

    # ──────────────────────────────────────────────────────────────────────
    # Claims Summary
    # ──────────────────────────────────────────────────────────────────────

    def _generate_claims_summary(self, members: List[Dict], claims: List[Dict],
                                  flags: List[Dict]) -> List[Dict]:
        today = date.today()
        summaries = []

        # Index claims and flags by member
        claims_by_member: Dict[str, List[Dict]] = {}
        for c in claims:
            claims_by_member.setdefault(c['MEMBER_ID'], []).append(c)

        flags_by_member: Dict[str, List[Dict]] = {}
        for f in flags:
            flags_by_member.setdefault(f['MEMBER_ID'], []).append(f)

        for member in members:
            member_id = member['MEMBER_ID']
            member_claims = claims_by_member.get(member_id, [])
            member_flags  = flags_by_member.get(member_id, [])

            if not member_claims:
                continue

            paid_claims   = [c for c in member_claims if c['CLAIM_STATUS'] == 'PAID']
            denied_claims = [c for c in member_claims if c['CLAIM_STATUS'] == 'DENIED']
            pending       = [c for c in member_claims if c['CLAIM_STATUS'] == 'PENDING']
            processed     = [c for c in member_claims if c['PROCESSING_HOURS'] is not None]

            total_billed  = sum(float(c['BILLED_AMOUNT']) for c in member_claims)
            total_allowed = sum(float(c['ALLOWED_AMOUNT']) for c in member_claims if c['ALLOWED_AMOUNT'])
            total_paid    = sum(float(c['PAID_AMOUNT']) for c in paid_claims)
            total_resp    = sum(float(c['MEMBER_RESPONSIBILITY']) for c in paid_claims)

            sla_checked  = [c for c in processed if c['SLA_MET'] is not None]
            sla_breaches = [c for c in sla_checked if c['SLA_MET'] == 'FALSE']
            sla_met_list = [c for c in sla_checked if c['SLA_MET'] == 'TRUE']

            proc_hours_list = [float(c['PROCESSING_HOURS']) for c in processed]
            avg_proc  = round(sum(proc_hours_list) / len(proc_hours_list), 2) if proc_hours_list else None
            max_proc  = round(max(proc_hours_list), 2) if proc_hours_list else None
            sorted_hrs = sorted(proc_hours_list)
            p90_idx   = int(0.90 * len(sorted_hrs))
            p90_proc  = round(sorted_hrs[p90_idx], 2) if sorted_hrs else None

            service_dates = [date.fromisoformat(c['SERVICE_DATE']) for c in member_claims]

            unique_providers = len(set(c['PROVIDER_NPI'] for c in member_claims))
            unique_types     = len(set(c['CLAIM_TYPE'] for c in member_claims))

            plan_year = today.year

            summaries.append({
                'SUMMARY_ID':             str(uuid.uuid5(uuid.NAMESPACE_OID, f'SH_SUM_{member_id}_{plan_year}')),
                'MEMBER_ID':              member_id,
                'PLAN_YEAR':              plan_year,
                'TOTAL_CLAIMS':           len(member_claims),
                'PAID_CLAIMS':            len(paid_claims),
                'DENIED_CLAIMS':          len(denied_claims),
                'PENDING_CLAIMS':         len(pending),
                'UNIQUE_PROVIDERS':       unique_providers,
                'UNIQUE_CLAIM_TYPES':     unique_types,
                'TOTAL_BILLED_AMOUNT':    round(total_billed, 2),
                'TOTAL_ALLOWED_AMOUNT':   round(total_allowed, 2),
                'TOTAL_PAID_AMOUNT':      round(total_paid, 2),
                'TOTAL_MEMBER_RESP':      round(total_resp, 2),
                'DENIAL_RATE':            round(len(denied_claims) / len(member_claims), 4),
                'SLA_BREACH_COUNT':       len(sla_breaches),
                'SLA_MET_COUNT':          len(sla_met_list),
                'SLA_BREACH_RATE':        round(len(sla_breaches) / max(len(sla_checked), 1), 4),
                'AVG_PROCESSING_HOURS':   avg_proc,
                'MAX_PROCESSING_HOURS':   max_proc,
                'P90_PROCESSING_HOURS':   p90_proc,
                'RISK_SCORE':             member['RISK_SCORE'],
                'PRIMARY_RISK_CATEGORY':  member['RISK_CATEGORY'],
                'ACTIVE_HCC_COUNT':       len([f for f in member_flags if f['FLAG_STATUS'] == 'ACTIVE']),
                'CHRONIC_CONDITION_COUNT': member['CHRONIC_CONDITION_COUNT'],
                'FIRST_SERVICE_DATE':     min(service_dates).isoformat(),
                'LAST_SERVICE_DATE':      max(service_dates).isoformat(),
                'LAST_UPDATED_TS':        datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
                '_SOURCE_SYSTEM':         'RISK_ADJ_PIPELINE',
                '_LOADED_AT':             datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            })

        print(f"  ✓ {len(summaries)} claims summary rows")
        return summaries

    # ──────────────────────────────────────────────────────────────────────
    # Helpers
    # ──────────────────────────────────────────────────────────────────────

    def _hash(self, *args) -> str:
        content = '|'.join(str(a) for a in args)
        return hashlib.sha256(content.encode()).hexdigest()

    def _generate_mbi(self) -> str:
        """Generate a synthetic CMS Medicare Beneficiary Identifier."""
        chars_1   = 'ACDEFGHJKMNPQRTVWXY'
        chars_2_9 = 'ACDEFGHJKMNPQRTVWXY0123456789'
        mbi  = random.choice(chars_1)
        mbi += random.choice('123456789')
        mbi += random.choice(chars_2_9)
        mbi += random.choice(chars_2_9)
        mbi += '-'
        mbi += random.choice(chars_2_9)
        mbi += random.choice(chars_2_9)
        mbi += '-'
        mbi += ''.join(random.choice('0123456789') for _ in range(4))
        return mbi


# ============================================================================
# CSV WRITER
# ============================================================================

def save_to_csv(records: List[Dict], filepath: str) -> None:
    if not records:
        print(f"  WARN: No records to write to {filepath}")
        return
    os.makedirs(os.path.dirname(filepath) if os.path.dirname(filepath) else '.', exist_ok=True)
    with open(filepath, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=records[0].keys(), quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(records)
    print(f"  → Wrote {len(records):,} rows to {os.path.basename(filepath)}")


# ============================================================================
# CLI ENTRY POINT
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description='Generate Sutter Health claims demo data')
    parser.add_argument('--output', default='../data', help='Output directory for CSV files')
    parser.add_argument('--quick',  action='store_true', help='Generate 10%% sample for quick testing')
    parser.add_argument('--scale',  type=float, default=1.0, help='Scale factor (1.0 = default, 2.0 = 2x)')
    parser.add_argument('--seed',   type=int,   default=42,  help='Random seed for reproducibility')
    args = parser.parse_args()

    counts = {
        'members':           int(1000 * args.scale),
        'providers':         int(200  * args.scale),
        'claims_per_member': 12,
    }
    if args.quick:
        counts = {k: max(1, int(v * 0.10)) for k, v in counts.items()}
        counts['claims_per_member'] = 12  # keep avg claims the same

    print(f"\nSutter Health Claims Data Generator")
    print(f"  Members:  {counts['members']:,}")
    print(f"  Providers:{counts['providers']:,}")
    print(f"  Avg claims/member: {counts['claims_per_member']}")
    print(f"  Output:   {args.output}\n")

    generator = SutterHealthClaimsGenerator(seed=args.seed)
    datasets  = generator.generate(counts)

    output_dir = args.output
    os.makedirs(output_dir, exist_ok=True)

    file_map = {
        'member_enrollment':      'member_enrollment.csv',
        'provider_directory':     'provider_directory.csv',
        'raw_claims':             'raw_claims.csv',
        'risk_adjustment_flags':  'risk_adjustment_flags.csv',
        'claims_summary':         'claims_summary.csv',
    }

    for key, filename in file_map.items():
        filepath = os.path.join(output_dir, filename)
        save_to_csv(datasets[key], filepath)

    total_rows = sum(len(v) for v in datasets.values())
    print(f"\nDone. {total_rows:,} total rows across {len(file_map)} files in {output_dir}/")


if __name__ == '__main__':
    main()
