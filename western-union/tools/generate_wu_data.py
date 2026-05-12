#!/usr/bin/env python3
"""
Western Union CDO Demo — Synthetic Data Generator

Generates realistic data for the Western Union CDO engagement focused on
data quality automation and semantic contracts:
  - WU_PAYMENTS: transactions, corridors, agents
  - WU_KYC: customers, beneficiaries, devices
  - WU_COMPLIANCE: watchlist_entities, sars, quality_issues

Intentionally injects ~1,000 quality issues across all tables that the
demo's DMF / contract system will detect and remediate.

Usage:
    python generate_wu_data.py --output ../data
    python generate_wu_data.py --output ../data --quick       # Small test set
    python generate_wu_data.py --output ../data --scale 2.0   # Double size
"""

import os
import sys
import random
import hashlib
import json
import csv
import argparse
from datetime import datetime, timedelta, date
from typing import List, Dict, Any

# Import base generator infrastructure from the core data_generator
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..', 'tools'))
from data_generator import SourceSystemGenerator, save_to_csv as base_save_to_csv

try:
    from faker import Faker
except ImportError:
    print("ERROR: Faker not installed. Run: pip install faker")
    sys.exit(1)


# ============================================================================
# REFERENCE DATA
# ============================================================================

# Sender origin countries with weights (WU perspective — US-centric outflows)
SENDER_COUNTRIES = [
    ("US", 0.65), ("MX", 0.04), ("PH", 0.02), ("IN", 0.03),
    ("GT", 0.02), ("CO", 0.02), ("UK", 0.06), ("DE", 0.04),
    ("FR", 0.03), ("AE", 0.04), ("CA", 0.03), ("IT", 0.02),
]

# Receiver destination countries with weights
RECEIVER_COUNTRIES = [
    ("MX", 0.25), ("PH", 0.12), ("IN", 0.15), ("GT", 0.08),
    ("CO", 0.07), ("PK", 0.08), ("NG", 0.06), ("TR", 0.05),
    ("MA", 0.04), ("BD", 0.05), ("SV", 0.03), ("HN", 0.02),
]

# Banks by country
BANKS_BY_COUNTRY = {
    "MX": ["Banorte", "BBVA Mexico", "Santander Mexico", "Banamex", "Banco Azteca"],
    "PH": ["BDO Unibank", "BPI", "Metrobank", "Landbank", "UnionBank"],
    "IN": ["State Bank of India", "HDFC Bank", "ICICI Bank", "Punjab National Bank", "Bank of Baroda"],
    "GT": ["Banco Industrial", "Banrural", "BAM Guatemala", "Banco G&T Continental"],
    "CO": ["Bancolombia", "Banco de Bogota", "Davivienda", "BBVA Colombia"],
    "PK": ["Habib Bank", "United Bank", "MCB Bank", "Allied Bank", "Bank Alfalah"],
    "NG": ["First Bank Nigeria", "Zenith Bank", "Access Bank", "GTBank", "UBA"],
    "TR": ["Ziraat Bankasi", "Is Bankasi", "Garanti BBVA", "Akbank", "Yapi Kredi"],
    "MA": ["Attijariwafa Bank", "BMCE Bank", "Banque Populaire", "CIH Bank"],
    "BD": ["Sonali Bank", "Janata Bank", "Agrani Bank", "BRAC Bank"],
    "SV": ["Banco Agricola", "Banco Cuscatlan", "Davivienda El Salvador"],
    "HN": ["Banco Atlantida", "BAC Credomatic", "Ficohsa"],
}

# Exchange rates (approximate USD to local currency)
EXCHANGE_RATES = {
    "MXN": 17.2, "PHP": 56.0, "INR": 83.5, "GTQ": 7.8,
    "COP": 3950.0, "PKR": 280.0, "NGN": 1550.0, "TRY": 32.0,
    "MAD": 10.0, "BDT": 110.0, "GBP": 0.79, "EUR": 0.92,
    "AED": 3.67, "SVC": 8.75, "HNL": 24.7, "CAD": 1.36,
}

# Country to currency mapping
COUNTRY_CURRENCY = {
    "US": "USD", "MX": "MXN", "PH": "PHP", "IN": "INR",
    "GT": "GTQ", "CO": "COP", "PK": "PKR", "NG": "NGN",
    "TR": "TRY", "MA": "MAD", "BD": "BDT", "UK": "GBP",
    "DE": "EUR", "FR": "EUR", "AE": "AED", "SV": "SVC",
    "HN": "HNL", "CA": "CAD", "IT": "EUR",
}

# Corridor risk tiers
CORRIDOR_RISK = {
    "US_MX": "LOW", "US_PH": "LOW", "US_IN": "LOW", "US_GT": "MEDIUM",
    "US_CO": "MEDIUM", "US_PK": "HIGH", "US_NG": "HIGH", "US_TR": "MEDIUM",
    "US_MA": "MEDIUM", "US_BD": "MEDIUM", "UK_PK": "HIGH", "UK_NG": "HIGH",
    "DE_TR": "MEDIUM", "FR_MA": "LOW", "AE_PK": "HIGH", "AE_BD": "HIGH",
    "US_SV": "MEDIUM", "US_HN": "MEDIUM", "CA_PH": "LOW", "CA_IN": "LOW",
}

# KYC statuses and weights
KYC_STATUSES = ["VERIFIED", "PENDING", "EXPIRED", "ENHANCED_DUE_DILIGENCE"]
KYC_STATUS_WEIGHTS = [0.75, 0.10, 0.10, 0.05]

KYC_METHODS = ["IN_PERSON", "REMOTE_VIDEO", "DOCUMENT_UPLOAD"]
KYC_METHOD_WEIGHTS = [0.40, 0.25, 0.35]

RISK_LEVELS = ["LOW", "MEDIUM", "HIGH", "PROHIBITED"]
RISK_LEVEL_WEIGHTS = [0.60, 0.25, 0.12, 0.03]

SOURCE_OF_FUNDS = ["EMPLOYMENT", "BUSINESS_INCOME", "INVESTMENT", "FAMILY_SUPPORT", "RETIREMENT"]
SOURCE_WEIGHTS = [0.50, 0.20, 0.10, 0.12, 0.08]

CHANNELS = ["DIGITAL", "RETAIL", "AGENT"]
CHANNEL_WEIGHTS = [0.45, 0.30, 0.25]

PAYMENT_METHODS = ["BANK_TRANSFER", "DEBIT_CARD", "CASH", "MOBILE_WALLET"]
PAYMENT_METHOD_WEIGHTS = [0.30, 0.25, 0.30, 0.15]

TXN_STATUSES = ["COMPLETED", "PENDING", "FAILED", "HELD"]
TXN_STATUS_WEIGHTS = [0.70, 0.15, 0.10, 0.05]

RELATIONSHIPS = ["FAMILY", "BUSINESS", "SELF", "OTHER"]
RELATIONSHIP_WEIGHTS = [0.45, 0.20, 0.20, 0.15]

AGENT_TYPES = ["RETAIL_STORE", "BANK_BRANCH", "MONEY_SERVICE", "DIGITAL_KIOSK"]
AGENT_TYPE_WEIGHTS = [0.40, 0.25, 0.25, 0.10]

PLATFORMS = ["IOS", "ANDROID", "WEB"]
PLATFORM_WEIGHTS = [0.40, 0.45, 0.15]

WATCHLIST_SOURCES = ["OFAC_SDN", "OFAC_CONS", "EU_SANCTIONS", "UN_SANCTIONS", "PEP", "INTERPOL"]
ENTITY_TYPES = ["INDIVIDUAL", "ORGANIZATION", "VESSEL"]

SAR_FILING_TYPES = ["INITIAL", "AMENDMENT", "CONTINUING_ACTIVITY"]
SAR_FILING_WEIGHTS = [0.55, 0.25, 0.20]

SAR_STATUSES = ["FILED", "UNDER_REVIEW", "CLOSED"]
SAR_STATUS_WEIGHTS = [0.50, 0.30, 0.20]

OCCUPATIONS = [
    "Construction Worker", "Restaurant Worker", "Healthcare Aide",
    "Driver", "Retail Associate", "Warehouse Worker", "IT Professional",
    "Engineer", "Teacher", "Small Business Owner", "Nurse",
    "Housekeeper", "Landscaper", "Factory Worker", "Office Worker",
]

# US cities for agents/customers
US_CITIES = [
    ("New York", "NY"), ("Los Angeles", "CA"), ("Chicago", "IL"), ("Houston", "TX"),
    ("Phoenix", "AZ"), ("Philadelphia", "PA"), ("San Antonio", "TX"), ("San Diego", "CA"),
    ("Dallas", "TX"), ("San Jose", "CA"), ("Austin", "TX"), ("Jacksonville", "FL"),
    ("Fort Worth", "TX"), ("Columbus", "OH"), ("Charlotte", "NC"), ("Indianapolis", "IN"),
    ("San Francisco", "CA"), ("Seattle", "WA"), ("Denver", "CO"), ("Nashville", "TN"),
    ("Miami", "FL"), ("Atlanta", "GA"), ("Portland", "OR"), ("Las Vegas", "NV"),
    ("Memphis", "TN"), ("Louisville", "KY"), ("Baltimore", "MD"), ("Milwaukee", "WI"),
    ("Albuquerque", "NM"), ("Tucson", "AZ"), ("Fresno", "CA"), ("Sacramento", "CA"),
    ("Mesa", "AZ"), ("Kansas City", "MO"), ("Omaha", "NE"), ("El Paso", "TX"),
    ("Raleigh", "NC"), ("Cleveland", "OH"), ("Tampa", "FL"), ("New Orleans", "LA"),
]

# WU agent name templates
AGENT_NAME_TEMPLATES = [
    "Western Union - {city} #{num}", "WU Agent {city} Downtown",
    "QuickSend #{num} - {city}", "MoneyGram Express {city}",
    "WU Express - {city} #{num}", "FastCash {city}",
    "WU Retail - {city} Mall", "PayPoint {city} #{num}",
    "WU Direct - {city} #{num}", "CashExpress {city} #{num}",
]

# Watchlist entity names (fictional)
WATCHLIST_NAMES = [
    "OCEANIC TRADING CONSORTIUM", "DESERT STAR HOLDINGS", "NORTHBRIDGE CAPITAL GROUP",
    "CRIMSON WAVE LOGISTICS", "GOLDEN PHOENIX ENTERPRISES", "IRON GATE SHIPPING LLC",
    "SILVER CRESCENT IMPORTS", "BLUE HORIZON VENTURES", "DARK RIVER COMMODITIES",
    "ATLAS PEAK FINANCIAL", "SAHARA WIND TRADING", "EMERALD PATH SOLUTIONS",
    "THUNDER BAY EXPORTS", "COPPER RIDGE MINING", "JADE MOUNTAIN HOLDINGS",
    "ARCTIC FLAME ENERGY", "CANYON BRIDGE CAPITAL", "PEARL HARBOR LOGISTICS",
    "FALCON RIDGE AVIATION", "STORM GATE INDUSTRIES", "SHADOW VALLEY RESOURCES",
    "SUNBURST GLOBAL TRADE", "MOONLIGHT MARITIME", "REDSTONE DEFENSE CORP",
    "CRYSTAL LAKE FINANCE", "GRANITE PEAK METALS", "OPAL COAST SHIPPING",
    "WILDFIRE ENERGY GROUP", "NIGHTFALL TECHNOLOGIES", "COBALT STREAM MINING",
]


DEFAULT_COUNTS = {
    'transactions': 200000,
    'corridors': 100,
    'agents': 5000,
    'customers': 50000,
    'beneficiaries': 30000,
    'devices': 20000,
    'watchlist_entities': 200,
    'sars': 500,
    'quality_issues': 1000,
}


# ============================================================================
# GENERATOR
# ============================================================================

class WUGenerator(SourceSystemGenerator):
    """Generates synthetic Western Union data with intentional quality issues."""

    SYSTEM_NAME = "WU_PAYMENTS"

    def __init__(self, seed: int = 42):
        self.seed = seed
        random.seed(seed)
        self.fake = Faker('en_US')
        self.fake.seed_instance(seed)
        self.customers: List[Dict] = []
        self.beneficiaries: List[Dict] = []
        self.agents: List[Dict] = []
        self.corridors: List[Dict] = []
        self.transactions: List[Dict] = []
        self.quality_issues: List[Dict] = []
        self._quality_issue_counter = 0

    def _hash(self, record: Dict) -> str:
        data = {k: v for k, v in record.items() if not k.startswith('_')}
        return hashlib.sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest()

    def _weighted_choice(self, items: list, weights: list):
        return random.choices(items, weights=weights, k=1)[0]

    def _add_quality_issue(self, source_table: str, record_id: str,
                           issue_type: str, description: str,
                           severity: str, expected: str, actual: str):
        """Track an intentionally injected quality issue."""
        self._quality_issue_counter += 1
        self.quality_issues.append({
            'quality_issue_id': f"QI-{self._quality_issue_counter:06d}",
            'source_table': source_table,
            'record_id': record_id,
            'issue_type': issue_type,
            'issue_description': description,
            'severity': severity,
            'expected_value': expected,
            'actual_value': actual,
            '_SOURCE_SYSTEM': 'WU_COMPLIANCE',
            '_ROW_HASH': None,
        })
        self.quality_issues[-1]['_ROW_HASH'] = self._hash(self.quality_issues[-1])

    # ------------------------------------------------------------------
    # CUSTOMERS (WU_KYC schema)
    # ------------------------------------------------------------------
    def generate_customers(self, count: int) -> List[Dict]:
        print(f"  Generating {count:,} customers...")
        records = []

        sender_countries = [c[0] for c in SENDER_COUNTRIES]
        sender_weights = [c[1] for c in SENDER_COUNTRIES]

        for i in range(count):
            country = self._weighted_choice(sender_countries, sender_weights)

            if country == "US":
                city, state = random.choice(US_CITIES)
            else:
                city = self.fake.city()
                state = ""

            first = self.fake.first_name()
            last = self.fake.last_name()
            full_name = f"{first} {last}"

            kyc_status = self._weighted_choice(KYC_STATUSES, KYC_STATUS_WEIGHTS)
            kyc_method = self._weighted_choice(KYC_METHODS, KYC_METHOD_WEIGHTS)
            risk_level = self._weighted_choice(RISK_LEVELS, RISK_LEVEL_WEIGHTS)

            # 10% have stale KYC (> 3 years old)
            if random.random() < 0.10:
                kyc_date = self.fake.date_between(start_date='-6y', end_date='-3y')
            else:
                kyc_date = self.fake.date_between(start_date='-3y', end_date='today')

            kyc_expiry = kyc_date + timedelta(days=365 * 3)
            account_created = self.fake.date_between(start_date='-5y', end_date='today')
            lifetime_value = round(random.uniform(100, 50000), 2)

            rec = {
                'customer_id': f"CU-{100000 + i:07d}",
                'first_name': first,
                'last_name': last,
                'full_name': full_name,
                'dob': self.fake.date_of_birth(minimum_age=18, maximum_age=75).isoformat(),
                'country': country,
                'state': state,
                'city': city,
                'address': self.fake.street_address(),
                'phone': self.fake.phone_number(),
                'email': self.fake.email(),
                'kyc_status': kyc_status,
                'kyc_method': kyc_method,
                'kyc_date': kyc_date.isoformat(),
                'kyc_expiry_date': kyc_expiry.isoformat(),
                'risk_level': risk_level,
                'source_of_funds': self._weighted_choice(SOURCE_OF_FUNDS, SOURCE_WEIGHTS),
                'occupation': random.choice(OCCUPATIONS),
                'lifetime_value_usd': lifetime_value,
                'account_created_at': datetime.combine(account_created, datetime.min.time()).isoformat(),
                '_SOURCE_SYSTEM': 'WU_KYC',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        self.customers = records
        return records

    # ------------------------------------------------------------------
    # BENEFICIARIES (WU_KYC schema)
    # ------------------------------------------------------------------
    def generate_beneficiaries(self, count: int) -> List[Dict]:
        if not self.customers:
            raise ValueError("Must generate customers first")
        print(f"  Generating {count:,} beneficiaries...")
        records = []

        receiver_countries = [c[0] for c in RECEIVER_COUNTRIES]
        receiver_weights = [c[1] for c in RECEIVER_COUNTRIES]

        for i in range(count):
            country = self._weighted_choice(receiver_countries, receiver_weights)
            banks = BANKS_BY_COUNTRY.get(country, ["International Bank"])
            relationship = self._weighted_choice(RELATIONSHIPS, RELATIONSHIP_WEIGHTS)
            customer = random.choice(self.customers)
            first_transfer = self.fake.date_between(start_date='-3y', end_date='today')
            total_transfers = random.randint(1, 100)
            total_amount = round(random.uniform(100, 50000), 2)

            rec = {
                'beneficiary_id': f"BN-{200000 + i:07d}",
                'customer_id': customer['customer_id'],
                'full_name': self.fake.name(),
                'country': country,
                'city': self.fake.city(),
                'bank_name': random.choice(banks),
                'account_number_masked': f"****{random.randint(1000, 9999)}",
                'relationship_type': relationship,
                'first_transfer_date': first_transfer.isoformat(),
                'total_transfers': total_transfers,
                'total_amount_usd': total_amount,
                '_SOURCE_SYSTEM': 'WU_KYC',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        self.beneficiaries = records
        return records

    # ------------------------------------------------------------------
    # DEVICES (WU_KYC schema)
    # ------------------------------------------------------------------
    def generate_devices(self, count: int) -> List[Dict]:
        if not self.customers:
            raise ValueError("Must generate customers first")
        print(f"  Generating {count:,} devices...")
        records = []

        for i in range(count):
            customer = random.choice(self.customers)
            platform = self._weighted_choice(PLATFORMS, PLATFORM_WEIGHTS)
            first_seen = self.fake.date_between(start_date='-2y', end_date='-1m')
            last_seen = self.fake.date_between(start_date='-1m', end_date='today')
            fingerprint = hashlib.sha256(f"device_{i}_{self.seed}".encode()).hexdigest()

            if platform == "IOS":
                model = random.choice(["iPhone 13", "iPhone 14", "iPhone 15", "iPhone 15 Pro"])
            elif platform == "ANDROID":
                model = random.choice(["Samsung Galaxy S23", "Pixel 7", "OnePlus 11", "Samsung Galaxy A54"])
            else:
                model = random.choice(["Chrome 120", "Safari 17", "Firefox 121", "Edge 120"])

            rec = {
                'device_id': f"DV-{600000 + i:07d}",
                'customer_id': customer['customer_id'],
                'fingerprint': fingerprint,
                'platform': platform,
                'device_model': model,
                'ip_country': customer['country'] if random.random() < 0.85 else random.choice(["US", "UK", "NG", "GH"]),
                'first_seen': first_seen.isoformat(),
                'last_seen': last_seen.isoformat(),
                'is_trusted': "TRUE" if random.random() < 0.80 else "FALSE",
                '_SOURCE_SYSTEM': 'WU_KYC',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        return records

    # ------------------------------------------------------------------
    # AGENTS (WU_PAYMENTS schema)
    # ------------------------------------------------------------------
    def generate_agents(self, count: int) -> List[Dict]:
        print(f"  Generating {count:,} agents...")
        records = []

        us_count = int(count * 0.80)

        for i in range(count):
            if i < us_count:
                city, state = random.choice(US_CITIES)
                country = "US"
            else:
                country = random.choice(["MX", "PH", "IN", "UK", "DE", "GT", "CO"])
                city = self.fake.city()
                state = ""

            agent_type = self._weighted_choice(AGENT_TYPES, AGENT_TYPE_WEIGHTS)
            template = random.choice(AGENT_NAME_TEMPLATES)
            agent_name = template.format(city=city, num=random.randint(100, 9999))

            onboard_date = self.fake.date_between(start_date='-8y', end_date='-6m')
            monthly_volume = random.randint(50000, 2000000)
            compliance_score = round(random.uniform(50, 100), 1)
            kyc_completion_rate = round(random.uniform(0.80, 1.0), 3)

            rec = {
                'agent_id': f"AG-{300000 + i:06d}",
                'agent_name': agent_name,
                'country': country,
                'city': city,
                'state': state,
                'agent_type': agent_type,
                'compliance_score': compliance_score,
                'monthly_volume': monthly_volume,
                'sar_count': random.choices([0, 1, 2, 3, 4, 5], weights=[0.60, 0.20, 0.10, 0.05, 0.03, 0.02])[0],
                'kyc_completion_rate': kyc_completion_rate,
                'onboarding_date': onboard_date.isoformat(),
                'last_audit_date': self.fake.date_between(start_date='-1y', end_date='today').isoformat(),
                'is_active': "TRUE" if random.random() < 0.90 else "FALSE",
                '_SOURCE_SYSTEM': 'WU_PAYMENTS',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        self.agents = records
        return records

    # ------------------------------------------------------------------
    # CORRIDORS (WU_PAYMENTS schema)
    # ------------------------------------------------------------------
    def generate_corridors(self, count: int) -> List[Dict]:
        print(f"  Generating {count:,} corridors...")
        records = []

        origin_countries = ["US", "UK", "DE", "FR", "AE", "CA", "AU", "JP", "KR", "IT"]
        dest_countries = ["MX", "PH", "IN", "GT", "CO", "PK", "NG", "TR", "MA", "BD",
                         "SV", "HN", "VN", "CN", "EG", "ET", "KE", "GH", "NP", "LK"]

        corridor_set = set()
        for corridor_code in CORRIDOR_RISK:
            origin, dest = corridor_code.split('_')
            corridor_set.add((origin, dest))

        while len(corridor_set) < count:
            origin = random.choice(origin_countries)
            dest = random.choice(dest_countries)
            if origin != dest:
                corridor_set.add((origin, dest))

        for idx, (origin, dest) in enumerate(corridor_set):
            if len(records) >= count:
                break

            corridor_code = f"{origin}_{dest}"
            risk = CORRIDOR_RISK.get(corridor_code, random.choice(["LOW", "MEDIUM", "HIGH"]))

            if risk in ("HIGH", "CRITICAL"):
                reg = random.choices(
                    ['BSA_REPORTING', 'GTO', 'ENHANCED_MONITORING'], weights=[0.3, 0.3, 0.4]
                )[0]
            elif risk == "MEDIUM":
                reg = random.choices(
                    ['STANDARD', 'GTO', 'ENHANCED_MONITORING'], weights=[0.6, 0.2, 0.2]
                )[0]
            else:
                reg = random.choices(
                    ['STANDARD', 'GTO', 'ENHANCED_MONITORING'], weights=[0.9, 0.05, 0.05]
                )[0]

            rec = {
                'corridor_id': f"CR-{400000 + idx:06d}",
                'origin_country': origin,
                'dest_country': dest,
                'corridor_code': corridor_code,
                'risk_tier': risk,
                'regulatory_regime': reg,
                'avg_daily_volume': random.randint(100000, 50000000),
                'avg_transaction_amount': random.randint(100, 2000),
                'fx_spread_pct': round(random.uniform(0.5, 4.0), 2),
                'is_active': "TRUE" if random.random() < 0.95 else "FALSE",
                '_SOURCE_SYSTEM': 'WU_PAYMENTS',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        self.corridors = records
        return records

    # ------------------------------------------------------------------
    # TRANSACTIONS (WU_PAYMENTS schema)
    # ------------------------------------------------------------------
    def generate_transactions(self, count: int) -> List[Dict]:
        if not self.customers or not self.agents:
            raise ValueError("Must generate customers and agents first")
        print(f"  Generating {count:,} transactions...")
        records = []

        active_agents = [a for a in self.agents if a['is_active'] == 'TRUE'] or self.agents
        receiver_countries = [c[0] for c in RECEIVER_COUNTRIES]
        receiver_weights = [c[1] for c in RECEIVER_COUNTRIES]

        for i in range(count):
            customer = random.choice(self.customers)
            agent = random.choice(active_agents)

            # Normal distribution: centered at $300, range $20-$9,999
            amount_usd = round(random.lognormvariate(5.7, 1.0), 2)
            amount_usd = max(20, min(9999, amount_usd))

            dest_country = self._weighted_choice(receiver_countries, receiver_weights)
            origin_country = customer['country']
            corridor = f"{origin_country}_{dest_country}"

            currency_local = COUNTRY_CURRENCY.get(dest_country, "USD")
            fx_rate = EXCHANGE_RATES.get(currency_local, 1.0) * random.uniform(0.97, 1.03)
            amount_local = round(amount_usd * fx_rate, 2)

            channel = self._weighted_choice(CHANNELS, CHANNEL_WEIGHTS)
            payment_method = self._weighted_choice(PAYMENT_METHODS, PAYMENT_METHOD_WEIGHTS)
            status = self._weighted_choice(TXN_STATUSES, TXN_STATUS_WEIGHTS)

            compliance_hold = False
            hold_reason = None
            if random.random() < 0.03:
                compliance_hold = True
                status = "HELD"
                hold_reason = random.choice([
                    "OFAC_MATCH", "THRESHOLD_EXCEEDED", "HIGH_RISK_CORRIDOR",
                    "STRUCTURING_SUSPECTED", "VELOCITY_ALERT",
                ])

            txn_date = self.fake.date_between(start_date='-2y', end_date='today')
            completed_at = None
            if status == "COMPLETED":
                completed_at = (datetime.combine(txn_date, datetime.min.time()) +
                               timedelta(minutes=random.randint(5, 1440))).isoformat()

            fee_pct = round(random.uniform(2.0, 8.0), 2)
            fee_usd = round(amount_usd * fee_pct / 100, 2)

            rec = {
                'transaction_id': f"TX-{500000 + i:08d}",
                'sender_id': customer['customer_id'],
                'receiver_id': random.choice(self.beneficiaries)['beneficiary_id'] if self.beneficiaries else None,
                'amount_usd': amount_usd,
                'amount_local': amount_local,
                'currency_local': currency_local,
                'fx_rate': round(fx_rate, 4),
                'corridor': corridor,
                'channel': channel,
                'agent_id': agent['agent_id'],
                'payment_method': payment_method,
                'status': status,
                'compliance_hold': str(compliance_hold).upper(),
                'hold_reason': hold_reason,
                'created_at': datetime.combine(txn_date, datetime.min.time()).isoformat(),
                'completed_at': completed_at,
                'fee_usd': fee_usd,
                'fee_pct': fee_pct,
                '_SOURCE_SYSTEM': 'WU_PAYMENTS',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        self.transactions = records
        return records

    # ------------------------------------------------------------------
    # WATCHLIST ENTITIES (WU_COMPLIANCE schema)
    # ------------------------------------------------------------------
    def generate_watchlist_entities(self, count: int) -> List[Dict]:
        print(f"  Generating {count:,} watchlist entities...")
        records = []

        names = list(WATCHLIST_NAMES)
        while len(names) < count:
            adj = random.choice(["DARK", "GOLDEN", "IRON", "SILVER", "SHADOW", "THUNDER",
                                "CRYSTAL", "FALCON", "ARCTIC", "CORAL", "GRANITE", "ONYX"])
            noun = random.choice(["PEAK", "RIVER", "GATE", "BRIDGE", "COAST", "RIDGE",
                                 "VALLEY", "HARBOR", "MOUNTAIN", "CREEK", "CANYON", "BAY"])
            suffix = random.choice(["HOLDINGS", "TRADING", "LOGISTICS", "ENTERPRISES",
                                   "SHIPPING", "CAPITAL", "INDUSTRIES", "VENTURES"])
            name = f"{adj} {noun} {suffix}"
            if name not in names:
                names.append(name)

        # Fictional countries for sanctions
        me_countries = ["Fictional Republic of Zaristan", "North Kaldavia",
                       "Greater Turkmenabad", "East Qalamistan", "Republic of Durvania"]
        af_countries = ["Republic of Bandara", "North Zamunda", "Kaluvia",
                       "Republic of Marothi", "East Gondwana"]
        other_countries = ["Novaria", "Republic of Eastholm", "South Valdoria",
                          "West Karelian Republic", "Republic of Meridia"]

        for i in range(count):
            name = names[i] if i < len(names) else f"ENTITY_{i}"
            list_source = random.choice(WATCHLIST_SOURCES)
            entity_type = random.choice(ENTITY_TYPES)

            roll = random.random()
            if roll < 0.30:
                country = random.choice(me_countries)
            elif roll < 0.60:
                country = random.choice(af_countries)
            else:
                country = random.choice(other_countries)

            alias_count = random.randint(1, 3)
            aliases = []
            for _ in range(alias_count):
                if entity_type == "INDIVIDUAL":
                    aliases.append(self.fake.name())
                else:
                    aliases.append(f"{random.choice(['GLOBAL', 'INTERNATIONAL', 'PACIFIC'])} {name.split()[1]} LTD")

            rec = {
                'entity_id': f"WL-{700000 + i:06d}",
                'entity_name': name,
                'list_source': list_source,
                'entity_type': entity_type,
                'country': country,
                'aliases': "|".join(aliases),
                'added_date': self.fake.date_between(start_date='-10y', end_date='today').isoformat(),
                '_SOURCE_SYSTEM': 'WU_COMPLIANCE',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        return records

    # ------------------------------------------------------------------
    # SARS (WU_COMPLIANCE schema)
    # ------------------------------------------------------------------
    def generate_sars(self, count: int) -> List[Dict]:
        if not self.customers:
            raise ValueError("Must generate customers first")
        print(f"  Generating {count:,} SARs...")
        records = []

        narratives = [
            "Customer conducted {txn_count} transactions totaling ${amount:,.0f} over {days} days, all below $3,000 threshold",
            "Multiple transfers to same beneficiary in {country} totaling ${amount:,.0f} with structuring indicators",
            "Account holder's transaction volume increased {mult}x over 30-day baseline, total ${amount:,.0f}",
            "Identity documents appear altered; customer unable to verify source of funds totaling ${amount:,.0f}",
            "Rapid-fire transactions totaling ${amount:,.0f} sent to high-risk corridor within {hours} hours",
            "Funnel account pattern: {count} unrelated senders directing funds through single account totaling ${amount:,.0f}",
        ]

        for i in range(count):
            customer = random.choice(self.customers)
            filing_type = self._weighted_choice(SAR_FILING_TYPES, SAR_FILING_WEIGHTS)
            sar_status = self._weighted_choice(SAR_STATUSES, SAR_STATUS_WEIGHTS)
            amount = random.uniform(5000, 500000)
            txn_count = random.randint(5, 50)

            narrative = random.choice(narratives).format(
                txn_count=txn_count, amount=amount,
                days=random.randint(3, 30),
                country=random.choice([c[0] for c in RECEIVER_COUNTRIES]),
                count=random.randint(3, 15),
                mult=random.randint(3, 10),
                hours=random.randint(2, 48),
            )

            filing_date = self.fake.date_between(start_date='-2y', end_date='today')

            rec = {
                'sar_id': f"SAR-{800000 + i:06d}",
                'customer_id': customer['customer_id'],
                'filing_type': filing_type,
                'amount_threshold_trigger': 3000.00 if random.random() < 0.6 else 10000.00,
                'total_amount': round(amount, 2),
                'filing_date': filing_date.isoformat(),
                'narrative': narrative,
                'status': sar_status,
                'investigator_id': f"INV-{random.randint(100, 999)}",
                '_SOURCE_SYSTEM': 'WU_COMPLIANCE',
                '_ROW_HASH': None,
            }
            rec['_ROW_HASH'] = self._hash(rec)
            records.append(rec)

        return records

    # ------------------------------------------------------------------
    # QUALITY ISSUES — Inject bad data INTO main tables
    # ------------------------------------------------------------------
    def inject_quality_issues(self, target_count: int):
        """Inject intentional quality issues across all tables.

        This mutates existing records in self.transactions, self.customers,
        self.beneficiaries and tracks each issue in self.quality_issues.
        """
        print(f"  Injecting ~{target_count:,} quality issues across tables...")
        self.quality_issues = []
        self._quality_issue_counter = 0

        # Distribute issues across types
        issue_counts = {
            'MISSING_CORRIDOR': 150,
            'EXPIRED_KYC': 150,
            'INVALID_COUNTRY_CODE': 100,
            'NEGATIVE_AMOUNT': 100,
            'NULL_BENEFICIARY_NAME': 100,
            'DUPLICATE_BENEFICIARY': 100,
            'MALFORMED_PHONE': 100,
            'STALE_KYC_NO_REVIEW': 100,
            'STRUCTURING_PATTERN': 100,
        }

        # Scale proportionally if target differs from 1000
        total_base = sum(issue_counts.values())
        if target_count != total_base:
            scale = target_count / total_base
            issue_counts = {k: max(1, int(v * scale)) for k, v in issue_counts.items()}

        # --- 1. MISSING_CORRIDOR: NULL corridor on transactions ---
        indices = random.sample(range(len(self.transactions)), min(issue_counts['MISSING_CORRIDOR'], len(self.transactions)))
        for idx in indices:
            txn = self.transactions[idx]
            original = txn['corridor']
            txn['corridor'] = None
            self._add_quality_issue(
                'WU_PAYMENTS.TRANSACTIONS', txn['transaction_id'],
                'MISSING_CORRIDOR', 'Transaction corridor field is NULL',
                'HIGH', f'corridor like XX_YY (was {original})', 'NULL')

        # --- 2. EXPIRED_KYC: customers with expired KYC but still VERIFIED ---
        verified = [i for i, c in enumerate(self.customers) if c['kyc_status'] == 'VERIFIED']
        sample_size = min(issue_counts['EXPIRED_KYC'], len(verified))
        indices = random.sample(verified, sample_size)
        for idx in indices:
            cust = self.customers[idx]
            expired_date = (date.today() - timedelta(days=random.randint(30, 365))).isoformat()
            original_expiry = cust['kyc_expiry_date']
            cust['kyc_expiry_date'] = expired_date
            # Keep kyc_status = VERIFIED (that's the bug)
            self._add_quality_issue(
                'WU_KYC.CUSTOMERS', cust['customer_id'],
                'EXPIRED_KYC', f'KYC expired on {expired_date} but status still VERIFIED',
                'CRITICAL', 'kyc_status=EXPIRED or kyc_expiry_date > today', f'kyc_expiry_date={expired_date}, kyc_status=VERIFIED')

        # --- 3. INVALID_COUNTRY_CODE: beneficiaries with full country names ---
        bad_countries = {
            "MX": "Mexico", "PH": "Philippines", "IN": "India",
            "GT": "Guatemala", "CO": "Colombia", "PK": "Pakistan",
            "NG": "Nigeria", "TR": "Turkey", "US": "United States",
        }
        indices = random.sample(range(len(self.beneficiaries)), min(issue_counts['INVALID_COUNTRY_CODE'], len(self.beneficiaries)))
        for idx in indices:
            bene = self.beneficiaries[idx]
            original = bene['country']
            bad_name = bad_countries.get(original, "United States")
            bene['country'] = bad_name
            self._add_quality_issue(
                'WU_KYC.BENEFICIARIES', bene['beneficiary_id'],
                'INVALID_COUNTRY_CODE', f'Country is full name "{bad_name}" instead of ISO code',
                'MEDIUM', f'ISO 2-letter code (e.g. {original})', bad_name)

        # --- 4. NEGATIVE_AMOUNT: transactions with negative amount_usd ---
        indices = random.sample(range(len(self.transactions)), min(issue_counts['NEGATIVE_AMOUNT'], len(self.transactions)))
        for idx in indices:
            txn = self.transactions[idx]
            original = txn['amount_usd']
            txn['amount_usd'] = -abs(original)
            self._add_quality_issue(
                'WU_PAYMENTS.TRANSACTIONS', txn['transaction_id'],
                'NEGATIVE_AMOUNT', f'Transaction amount is negative: {txn["amount_usd"]}',
                'CRITICAL', 'amount_usd > 0', str(txn['amount_usd']))

        # --- 5. NULL_BENEFICIARY_NAME: beneficiaries with NULL full_name ---
        indices = random.sample(range(len(self.beneficiaries)), min(issue_counts['NULL_BENEFICIARY_NAME'], len(self.beneficiaries)))
        for idx in indices:
            bene = self.beneficiaries[idx]
            original = bene['full_name']
            bene['full_name'] = None
            self._add_quality_issue(
                'WU_KYC.BENEFICIARIES', bene['beneficiary_id'],
                'NULL_BENEFICIARY_NAME', 'Beneficiary full_name is NULL',
                'HIGH', 'non-null full_name', 'NULL')

        # --- 6. DUPLICATE_BENEFICIARY: insert duplicate beneficiaries ---
        dup_count = issue_counts['DUPLICATE_BENEFICIARY']
        source_indices = random.sample(range(len(self.beneficiaries)), min(dup_count, len(self.beneficiaries)))
        for idx in source_indices:
            original = self.beneficiaries[idx]
            dup = dict(original)
            dup['beneficiary_id'] = f"BN-{200000 + len(self.beneficiaries):07d}"
            dup['_ROW_HASH'] = self._hash(dup)
            self.beneficiaries.append(dup)
            self._add_quality_issue(
                'WU_KYC.BENEFICIARIES', dup['beneficiary_id'],
                'DUPLICATE_BENEFICIARY',
                f'Duplicate of {original["beneficiary_id"]}: same customer_id={original["customer_id"]}, name={original["full_name"]}, country={original["country"]}',
                'MEDIUM', 'unique customer_id+full_name+country', f'duplicate of {original["beneficiary_id"]}')

        # --- 7. MALFORMED_PHONE: customers with bad phone format ---
        indices = random.sample(range(len(self.customers)), min(issue_counts['MALFORMED_PHONE'], len(self.customers)))
        for idx in indices:
            cust = self.customers[idx]
            original = cust['phone']
            bad_phone = random.choice([
                f"{random.randint(100,999)}{random.randint(1000000,9999999)}",  # no formatting
                f"+{random.randint(1,99)}-{random.randint(0,9)}",  # truncated
                "N/A",
                "",
                f"({random.randint(100,999)}) {random.randint(100,999)}-{random.randint(10,99)}",  # short
            ])
            cust['phone'] = bad_phone
            self._add_quality_issue(
                'WU_KYC.CUSTOMERS', cust['customer_id'],
                'MALFORMED_PHONE', f'Phone number malformed: "{bad_phone}"',
                'LOW', 'valid phone format', bad_phone)

        # --- 8. STALE_KYC_NO_REVIEW: KYC > 3 years old, no re-verification ---
        stale_candidates = [i for i, c in enumerate(self.customers)
                           if c['kyc_date'] < (date.today() - timedelta(days=365*3)).isoformat()
                           and c['kyc_status'] == 'VERIFIED']
        # If not enough stale candidates, force some
        if len(stale_candidates) < issue_counts['STALE_KYC_NO_REVIEW']:
            extra_needed = issue_counts['STALE_KYC_NO_REVIEW'] - len(stale_candidates)
            non_stale = [i for i in range(len(self.customers)) if i not in stale_candidates]
            extra = random.sample(non_stale, min(extra_needed, len(non_stale)))
            for idx in extra:
                self.customers[idx]['kyc_date'] = self.fake.date_between(
                    start_date='-6y', end_date='-3y').isoformat()
                self.customers[idx]['kyc_status'] = 'VERIFIED'
                stale_candidates.append(idx)

        for idx in stale_candidates[:issue_counts['STALE_KYC_NO_REVIEW']]:
            cust = self.customers[idx]
            self._add_quality_issue(
                'WU_KYC.CUSTOMERS', cust['customer_id'],
                'STALE_KYC_NO_REVIEW',
                f'KYC date {cust["kyc_date"]} is >3 years old with no re-verification',
                'HIGH', 'kyc_date within 3 years or kyc_status=EXPIRED', f'kyc_date={cust["kyc_date"]}, status=VERIFIED')

        # --- 9. STRUCTURING_PATTERN: sequences below $3,000 from same sender ---
        struct_count = issue_counts['STRUCTURING_PATTERN']
        # Pick random senders and create sequences of 3-5 transactions just below $3K
        sender_pool = random.sample(range(len(self.customers)), min(struct_count // 3, len(self.customers)))
        struct_injected = 0
        for sender_idx in sender_pool:
            if struct_injected >= struct_count:
                break
            customer = self.customers[sender_idx]
            sender_id = customer['customer_id']
            seq_len = random.randint(3, 5)
            base_date = self.fake.date_between(start_date='-6m', end_date='today')

            for j in range(seq_len):
                if struct_injected >= struct_count:
                    break
                amount = round(random.uniform(2800, 2999), 2)
                txn_date = base_date + timedelta(hours=random.randint(1, 48))
                agent = random.choice(self.agents)

                rec = {
                    'transaction_id': f"TX-{500000 + len(self.transactions):08d}",
                    'sender_id': sender_id,
                    'receiver_id': random.choice(self.beneficiaries)['beneficiary_id'] if self.beneficiaries else None,
                    'amount_usd': amount,
                    'amount_local': round(amount * 17.2, 2),
                    'currency_local': 'MXN',
                    'fx_rate': 17.2,
                    'corridor': f"{customer['country']}_MX",
                    'channel': 'RETAIL',
                    'agent_id': agent['agent_id'],
                    'payment_method': 'CASH',
                    'status': 'COMPLETED',
                    'compliance_hold': 'FALSE',
                    'hold_reason': None,
                    'created_at': datetime.combine(txn_date, datetime.min.time()).isoformat(),
                    'completed_at': (datetime.combine(txn_date, datetime.min.time()) + timedelta(minutes=15)).isoformat(),
                    'fee_usd': round(amount * 0.04, 2),
                    'fee_pct': 4.0,
                    '_SOURCE_SYSTEM': 'WU_PAYMENTS',
                    '_ROW_HASH': None,
                }
                rec['_ROW_HASH'] = self._hash(rec)
                self.transactions.append(rec)

                self._add_quality_issue(
                    'WU_PAYMENTS.TRANSACTIONS', rec['transaction_id'],
                    'STRUCTURING_PATTERN',
                    f'Transaction ${amount:.2f} from {sender_id} just below $3,000 threshold (sequence {j+1}/{seq_len})',
                    'CRITICAL', 'normal transaction pattern', f'${amount:.2f} from {sender_id} in rapid sequence')
                struct_injected += 1

        print(f"  Injected {len(self.quality_issues):,} quality issues across {len(issue_counts)} types")

    # ------------------------------------------------------------------
    # ORCHESTRATOR
    # ------------------------------------------------------------------
    def generate(self, counts: Dict[str, int]) -> Dict[str, List[Dict]]:
        data = {}

        # Generate in dependency order
        data['customers'] = self.generate_customers(counts.get('customers', 50000))
        data['beneficiaries'] = self.generate_beneficiaries(counts.get('beneficiaries', 30000))
        data['devices'] = self.generate_devices(counts.get('devices', 20000))
        data['agents'] = self.generate_agents(counts.get('agents', 5000))
        data['corridors'] = self.generate_corridors(counts.get('corridors', 100))
        data['transactions'] = self.generate_transactions(counts.get('transactions', 200000))
        data['watchlist_entities'] = self.generate_watchlist_entities(counts.get('watchlist_entities', 200))
        data['sars'] = self.generate_sars(counts.get('sars', 500))

        # Inject quality issues (mutates existing records + adds quality_issues table)
        self.inject_quality_issues(counts.get('quality_issues', 1000))
        data['quality_issues'] = self.quality_issues

        return data


# ============================================================================
# OUTPUT — Save to three schema-aligned folders
# ============================================================================

def save_to_csv(data: Dict[str, List[Dict]], output_dir: str):
    """Save data into schema-aligned subfolders matching Snowflake RAW schemas."""

    # Map tables to their target schema folders
    schema_map = {
        'wu_payments': ['transactions', 'corridors', 'agents'],
        'wu_kyc': ['customers', 'beneficiaries', 'devices'],
        'wu_compliance': ['watchlist_entities', 'sars', 'quality_issues'],
    }

    for schema_name, tables in schema_map.items():
        schema_data = {t: data[t] for t in tables if t in data and data[t]}
        if schema_data:
            base_save_to_csv(schema_data, output_dir, schema_name)


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Generate Western Union CDO demo data for Snowflake DCA",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python generate_wu_data.py --output ../data
  python generate_wu_data.py --output ../data --quick
  python generate_wu_data.py --output ../data --scale 2.0
  python generate_wu_data.py --output ../data --seed 123
        """
    )
    parser.add_argument("--output", "-o", default="../data",
                       help="Output directory (default: ../data)")
    parser.add_argument("--seed", type=int, default=42,
                       help="Random seed for reproducibility (default: 42)")
    parser.add_argument("--quick", action="store_true",
                       help="Generate small test dataset (~10%% of default)")
    parser.add_argument("--scale", type=float, default=1.0,
                       help="Scale factor for record counts (default: 1.0)")

    args = parser.parse_args()
    counts = dict(DEFAULT_COUNTS)
    if args.quick:
        counts = {k: max(10, v // 10) for k, v in counts.items()}
    else:
        counts = {k: int(v * args.scale) for k, v in counts.items()}

    print("=" * 60)
    print("WESTERN UNION CDO DEMO — DATA GENERATOR")
    print("=" * 60)
    print(f"  Seed:   {args.seed}")
    print(f"  Scale:  {'quick (10%)' if args.quick else f'{args.scale}x'}")
    print(f"  Output: {args.output}")
    print(f"  Counts: {counts}")
    print()

    generator = WUGenerator(seed=args.seed)
    data = generator.generate(counts)

    print()
    print("=" * 60)
    print("GENERATION COMPLETE")
    print("=" * 60)
    for table, records in data.items():
        print(f"  {table}: {len(records):,} records")

    # Quality issue distribution
    print()
    print("QUALITY ISSUES BY TYPE:")
    issue_dist: Dict[str, int] = {}
    for qi in data.get('quality_issues', []):
        t = qi['issue_type']
        issue_dist[t] = issue_dist.get(t, 0) + 1
    for itype, icount in sorted(issue_dist.items(), key=lambda x: -x[1]):
        print(f"  {itype}: {icount}")

    print()
    save_to_csv(data, args.output)
    print("\nDone!")


if __name__ == "__main__":
    main()
