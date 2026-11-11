"""Синтетический банк: клиенты, карты, операции с подложенным мошенничеством, кредиты.

Всё выводится из seed. Один и тот же день всегда даёт одни и те же строки, поэтому
перегенерация дня идемпотентна, а Airflow может догружать день за днём.

Мошенничество четырёх видов (то, что потом ловят правила в хранилище):
- VELOCITY  — серия онлайн-покупок с чужого устройства за час;
- AMOUNT    — покупка в 8–20 раз дороже обычной для карты;
- GEO       — покупка в Казахстане, через 0,5–2 ч — за границей;
- ATO       — захват аккаунта (account takeover): ночные переводы P2P с нового устройства.
Жалоба (fraud_reports) приходит по 90 % случаев, через 1–14 дней.
"""
from __future__ import annotations

import math
import random
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from functools import cached_property

CITIES = ["Almaty", "Astana", "Shymkent", "Karaganda", "Aktobe", "Atyrau", "Pavlodar", "Oskemen"]
CITY_WEIGHTS = [30, 20, 12, 8, 7, 6, 6, 5]
FIRST_NAMES = ["Aidar", "Aigerim", "Arman", "Dana", "Daniyar", "Madina", "Nurlan", "Aliya",
               "Yerlan", "Saule", "Timur", "Anna", "Dmitry", "Olga", "Sergey", "Zarina"]
LAST_NAMES = ["Abenov", "Akhmetova", "Bekov", "Dzhaksybekov", "Ivanov", "Kim", "Nurpeisova",
              "Omarov", "Petrova", "Sadykov", "Tulegenova", "Zhumabaev"]
MCC = {"5411": "Grocery", "5812": "Restaurant", "5541": "Fuel", "5311": "Department store",
       "5732": "Electronics", "4111": "Transport", "5999": "Shop", "5944": "Jewelry",
       "5912": "Pharmacy", "7832": "Cinema"}
FOREIGN = ["TR", "AE", "CN", "US", "GE", "UZ"]

SCENARIO_SEQ = 800_000        # честные операции внутри сценариев (покупка дома перед GEO)
FRAUD_SEQ = 900_000           # номера мошеннических операций внутри дня — только отсюда
REPORT_SHARE = 0.9
REPORT_MAX_DELAY = 14
FRAUD_KINDS = ["VELOCITY", "AMOUNT", "GEO", "ATO"]
FRAUD_WEIGHTS = [35, 25, 25, 15]
ANNUAL_RATE = 0.25


@dataclass(frozen=True)
class Config:
    seed: int = 42
    n_clients: int = 50_000
    n_merchants: int = 2_000
    n_loans: int = 15_000
    start: date = date(2026, 5, 1)        # первый день истории операций
    horizon_days: int = 366               # дальше start + horizon кредиты не выдаются
    trx_per_card_day: float = 0.3
    fraud_cases_per_day: float = 6.0


@dataclass(frozen=True)
class Card:
    card_id: int
    client_id: int
    mean_amount: float     # типичная сумма покупки по этой карте
    activity: float        # вес: насколько часто карта платит


@dataclass(frozen=True)
class FraudCase:
    kind: str
    rows: list[tuple]      # строки transactions, включая честные операции сценария
    fraud_ids: list[int]   # только мошеннические trx_id


def _rng(cfg: Config, *parts: object) -> random.Random:
    # строковый seed хешируется sha512 — результат не зависит от PYTHONHASHSEED
    return random.Random("|".join(map(str, (cfg.seed, *parts))))


def _day_id(day: date, seq: int) -> int:
    return int(day.strftime("%Y%m%d")) * 1_000_000 + seq


def add_months(d: date, months: int) -> date:
    y, m = divmod(d.month - 1 + months, 12)
    y, m = d.year + y, m + 1
    nxt = date(y + m // 12, m % 12 + 1, 1)
    return date(y, m, min(d.day, (nxt - timedelta(days=1)).day))


def _at(day: date, seconds: float) -> datetime:
    return datetime(day.year, day.month, day.day) + timedelta(seconds=int(seconds))


class Bank:
    """Статичная часть мира (клиенты, карты, продавцы, кредиты) + генерация по дням."""

    def __init__(self, cfg: Config = Config()):
        self.cfg = cfg
        r = _rng(cfg, "world")
        self.clients: list[tuple] = []
        self.cards: list[Card] = []
        self.card_rows: list[tuple] = []
        for cid in range(1, cfg.n_clients + 1):
            premium = r.random() < 0.1
            reg = cfg.start - timedelta(days=r.randint(30, 6 * 365))
            self.clients.append((
                cid, f"{r.choice(FIRST_NAMES)} {r.choice(LAST_NAMES)}",
                date(r.randint(1960, 2006), r.randint(1, 12), r.randint(1, 28)),
                r.choices(CITIES, CITY_WEIGHTS)[0], "PREMIUM" if premium else "MASS", reg, reg,
            ))
            for k in range(1 if r.random() < 0.65 else 2):
                card_id = cid * 10 + k
                typical = 25_000 if premium else 7_000
                self.cards.append(Card(card_id, cid, r.lognormvariate(math.log(typical), 0.5),
                                       r.lognormvariate(0, 0.7)))
                self.card_rows.append((card_id, cid, "CREDIT" if k else "DEBIT",
                                       reg + timedelta(days=r.randint(0, 30))))
        self._cum_activity = []
        total = 0.0
        for c in self.cards:
            total += c.activity
            self._cum_activity.append(total)

        self.merchants: list[tuple] = []
        for mid in range(1, cfg.n_merchants + 1):
            mcc = r.choice(list(MCC))
            country = r.choice(FOREIGN) if r.random() < 0.1 else "KZ"
            self.merchants.append((mid, f"{MCC[mcc]} #{mid:04d}", mcc, country))
        self._domestic = [m for m in self.merchants if m[3] == "KZ"]
        self._foreign = [m for m in self.merchants if m[3] != "KZ"]
        self._pricey = [m for m in self.merchants if m[2] in ("5732", "5944")]

    # ---------- кредиты ----------

    @cached_property
    def _loans(self) -> tuple[list[tuple], dict[date, list[tuple[int, float]]]]:
        cfg, r = self.cfg, _rng(self.cfg, "loans")
        first, last = cfg.start - timedelta(days=720), cfg.start + timedelta(days=cfg.horizon_days)
        span = (last - first).days
        loans, payments = [], {}
        for loan_id in range(1, cfg.n_loans + 1):
            issued = first + timedelta(days=r.randrange(span))
            principal = round(r.lognormvariate(math.log(1_500_000), 0.6), -4) or 10_000
            term = r.choice([12, 24, 36])
            i = ANNUAL_RATE / 12
            monthly = round(principal * i / (1 - (1 + i) ** -term), 2)
            loans.append((loan_id, r.randint(1, cfg.n_clients), issued, principal, term, monthly))
            behaviour = r.choices(["GOOD", "LATE", "DEFAULT"], [85, 10, 5])[0]
            stop_after = r.randint(2, term - 1) if behaviour == "DEFAULT" else term
            for k in range(1, stop_after + 1):
                due = add_months(issued, k)
                if behaviour == "LATE" and r.random() < 0.4:
                    paid = due + timedelta(days=r.randint(1, 45))
                else:
                    paid = due - timedelta(days=r.randint(0, 3))
                if paid <= last:
                    payments.setdefault(paid, []).append((loan_id, monthly))
        return loans, payments

    def loans_issued(self, first: date | None, last: date) -> list[tuple]:
        """Кредиты, выданные в [first, last]; first=None — с самого начала."""
        return [l for l in self._loans[0] if (first is None or l[2] >= first) and l[2] <= last]

    def payments(self, day: date) -> list[tuple]:
        return [(_day_id(day, seq), loan_id, day, amount)
                for seq, (loan_id, amount) in enumerate(self._loans[1].get(day, []), 1)]

    def payments_before(self, day: date) -> list[tuple]:
        return [row for d in sorted(self._loans[1]) if d < day for row in self.payments(d)]

    # ---------- операции ----------

    def transactions(self, day: date) -> list[tuple]:
        """Все операции дня: честные + мошеннические сценарии этого дня."""
        cfg, r = self.cfg, _rng(self.cfg, "trx", day)
        weekend = 1.15 if day.weekday() >= 4 else 1.0
        n = round(len(self.cards) * cfg.trx_per_card_day * weekend * r.uniform(0.95, 1.05))
        picked = r.choices(self.cards, cum_weights=self._cum_activity, k=n)
        rows = [self._legit(r, day, seq, card) for seq, card in enumerate(picked, 1)]
        for case in self.fraud_cases(day):
            rows.extend(case.rows)
        return rows

    def _legit(self, r: random.Random, day: date, seq: int, card: Card) -> tuple:
        channel = r.choices(["POS", "ONLINE", "ATM", "P2P"], [55, 20, 10, 15])[0]
        # днём платят чаще, ночью почти нет
        hour = r.choices(range(24), [1, 1, 1, 1, 1, 2, 4, 6, 8, 9, 9, 9, 10, 10, 9, 9, 9, 10, 10, 9, 8, 6, 4, 2])[0]
        ts = _at(day, hour * 3600 + r.randrange(3600))
        amount = max(100.0, r.lognormvariate(math.log(card.mean_amount), 0.6))
        merchant, country, device = None, "KZ", None
        if channel == "POS":
            merchant = r.choice(self._foreign if r.random() < 0.003 else self._domestic)  # поездки
            country = merchant[3]
        elif channel == "ONLINE":
            merchant = r.choice(self.merchants)
            country, device = merchant[3], f"D{card.client_id}"
        elif channel == "ATM":
            amount = max(1000.0, round(amount * 2, -3))
        else:
            device = f"D{card.client_id}"
        status = "DECLINED" if r.random() < 0.02 else "APPROVED"
        return (_day_id(day, seq), card.card_id, merchant and merchant[0], ts,
                round(amount, 2), channel, country, device, status)

    def fraud_cases(self, day: date) -> list[FraudCase]:
        r = _rng(self.cfg, "fraud", day)
        k = max(0, round(r.gauss(self.cfg.fraud_cases_per_day, 2)))
        seq = {"fraud": FRAUD_SEQ, "legit": SCENARIO_SEQ}
        cases = []
        for _ in range(k):
            card = r.choice(self.cards)
            kind = r.choices(FRAUD_KINDS, FRAUD_WEIGHTS)[0]
            fake_device = f"F{r.getrandbits(40):010x}"
            fraud_rows, legit_rows = [], []

            def trx(ts, merchant, amount, channel, country, device, rows):
                key = "fraud" if rows is fraud_rows else "legit"
                seq[key] += 1
                status = "DECLINED" if key == "fraud" and r.random() < 0.25 else "APPROVED"
                rows.append((_day_id(day, seq[key]), card.card_id, merchant and merchant[0], ts,
                             round(amount, 2), channel, country, device, status))

            if kind == "VELOCITY":
                ts = _at(day, r.randrange(22 * 3600))
                for _ in range(r.randint(6, 15)):
                    m = r.choice(self.merchants)
                    trx(ts, m, r.uniform(500, 5000), "ONLINE", m[3], fake_device, fraud_rows)
                    ts += timedelta(minutes=r.randint(1, 6))
            elif kind == "AMOUNT":
                ts = _at(day, r.randrange(8 * 3600, 23 * 3600))
                for _ in range(r.randint(1, 2)):
                    m = r.choice(self._pricey)
                    trx(ts, m, card.mean_amount * r.uniform(8, 20), "ONLINE", m[3], fake_device, fraud_rows)
                    ts += timedelta(minutes=r.randint(5, 40))
            elif kind == "GEO":
                ts = _at(day, r.randrange(6 * 3600, 20 * 3600))
                home = r.choice(self._domestic)
                trx(ts, home, card.mean_amount * r.uniform(0.5, 1.5), "POS", "KZ", None, legit_rows)
                ts += timedelta(minutes=r.randint(30, 120))
                for _ in range(r.randint(1, 3)):
                    m = r.choice(self._foreign)
                    trx(ts, m, card.mean_amount * r.uniform(2, 6), "POS", m[3], None, fraud_rows)
                    ts += timedelta(minutes=r.randint(3, 30))
            else:  # ATO
                ts = _at(day, r.randrange(1 * 3600, 5 * 3600))
                for _ in range(r.randint(1, 3)):
                    trx(ts, None, card.mean_amount * r.uniform(5, 15), "P2P", "KZ", fake_device, fraud_rows)
                    ts += timedelta(minutes=r.randint(2, 15))

            cases.append(FraudCase(kind, legit_rows + fraud_rows, [row[0] for row in fraud_rows]))
        return cases

    def fraud_reports(self, day: date) -> list[tuple]:
        """Жалобы, пришедшие в этот день: по случаям прошлых 1–14 дней."""
        rows = []
        for back in range(1, REPORT_MAX_DELAY + 1):
            src_day = day - timedelta(days=back)
            if src_day < self.cfg.start:
                break
            for i, case in enumerate(self.fraud_cases(src_day)):
                r = _rng(self.cfg, "report", src_day, i)
                if r.random() < REPORT_SHARE and r.randint(1, REPORT_MAX_DELAY) == back:
                    rows.extend((trx_id, day, case.kind) for trx_id in case.fraud_ids)
        return rows

    # ---------- изменения клиентов (для SCD2 в хранилище) ----------

    def client_updates(self, day: date) -> list[tuple]:
        """(city, segment, updated_at, client_id). Иногда значения не меняются —
        как в жизни: запись «обновили», а по сути то же самое."""
        r = _rng(self.cfg, "upd", day)
        return [(r.choices(CITIES, CITY_WEIGHTS)[0], r.choices(["MASS", "PREMIUM"], [9, 1])[0],
                 day, r.randint(1, self.cfg.n_clients))
                for _ in range(r.randint(20, 60))]
