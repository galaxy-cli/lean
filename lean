#!/usr/bin/env python3
"""lean - track calorie deficit and body fat estimates.

Self-contained: creates its own SQLite database at
~/.local/share/lean/lean.db on first run. Pure standard library, so
unlike brief there's no venv/dependency bootstrapping needed at all.

Data model: a single append-only `entries` table. Each edit inserts one
new timestamped row with only the fields relevant to that edit filled in
(everything else NULL) -- a partial snapshot, not a full record. Every
calculation resolves "the most recently known value of field X" by
scanning backward through entries independently per field, so e.g.
logging today's weight doesn't require re-entering your waist and neck,
and vice versa. See get_latest() and iter_snapshots-style scans below.

The one deliberate exception to "append-only" is `--edit --clear`, which
removes all stored rows/values for a topic.
"""
import argparse
import math
import os
import re
import sqlite3
import sys
from datetime import datetime

APP_DIR = os.path.expanduser("~/.local/share/lean")
DB_PATH = os.path.join(APP_DIR, "lean.db")

ACTIVITY_LEVELS = {
    "sedentary": 1.2,
    "light": 1.375,
    "moderate": 1.55,
    "very": 1.725,
    "athlete": 1.9,
}

# Standard ACE body-fat ranges, ordered low to high, per sex.
BODYFAT_CATEGORIES = {
    "m": [("Essential Fat", 0, 5), ("Athletes", 6, 13), ("Fitness", 14, 17),
          ("Average", 18, 24), ("Obese", 25, 999)],
    "f": [("Essential Fat", 0, 13), ("Athletes", 14, 20), ("Fitness", 21, 24),
          ("Average", 25, 31), ("Obese", 32, 999)],
}

FIELDS = ["sex", "height_cm", "age", "activity_level", "weight_kg",
          "intake_kcal", "waist_cm", "neck_cm", "hip_cm"]

# Which stored columns belong to each topic (used by --clear). deficit and
# weightloss are calculated from other data, so they own none.
TOPIC_FIELDS = {
    "profile": ["sex", "height_cm", "age", "activity_level", "weight_kg", "intake_kcal"],
    "bodyfat": ["waist_cm", "neck_cm", "hip_cm"],
}
TOPIC_LABELS = {"profile": "profile (including weight and intake)"}


# --- UNIT PARSING -----------------------------------------------------
# Kept deliberately simple for a first draft: lengths default to cm when
# no unit is given, mass defaults to lb (matching how most people in
# practice think of body weight) -- documented via the prompt hints.

def add_decimal(raw):
    """Give a leading whole number a decimal part: "228lb" -> "228.0lb".
    Numbers that already have one are left alone."""
    return re.sub(r"^(\d+)(?![\d.])", r"\1.0", raw.strip())


def parse_length(raw, label, require_unit=False):
    """Parse a height/circumference measurement into centimeters.
    Accepts "178cm", "70in", "5'10\"", or a bare number (assumed cm).
    With require_unit=True only an explicit in or cm value is accepted
    (e.g. "15in", "38.1 cm"); bare numbers and feet'inches are rejected."""
    raw = raw.strip().lower()
    if require_unit:
        raw = add_decimal(raw)
        m = re.match(r"^(\d+(?:\.\d+)?)\s*(cm|in|inch|inches)$", raw)
        if not m:
            raise ValueError(f"Include a unit for {label} (in or cm), like 15in or 38.1cm")
        val = float(m.group(1))
        if val <= 0:
            raise ValueError(f"{label.capitalize()} must be greater than 0")
        return val * 2.54 if m.group(2).startswith("in") else val
    m = re.match(r"^(\d+)'\s*(\d+(?:\.\d+)?)\"?$", raw)
    if m:
        feet, inches = float(m.group(1)), float(m.group(2))
        return (feet * 12 + inches) * 2.54
    raw = add_decimal(raw)
    m = re.match(r"^([\d.]+)\s*(cm|in|inch|inches)?$", raw)
    if m:
        val = float(m.group(1))
        unit = m.group(2) or "cm"
        return val * 2.54 if unit.startswith("in") else val
    raise ValueError(f"Could not parse {label} -- try e.g. 178cm or 5'10\"")


def parse_mass(raw, label):
    """Parse a weight measurement into kilograms.
    Accepts "72kg", "160lb", "160lbs", or a bare number (assumed lb)."""
    raw = add_decimal(raw.strip().lower())
    m = re.match(r"^([\d.]+)\s*(kg|lb|lbs|pounds?)?$", raw)
    if m:
        val = float(m.group(1))
        unit = m.group(2) or "lb"
        return val if unit == "kg" else val / 2.20462
    raise ValueError(f"Could not parse {label} -- try e.g. 160lb or 72kg")


def parse_sex(raw):
    raw = raw.strip().lower()
    if raw in ("m", "male"):
        return "m"
    if raw in ("f", "female"):
        return "f"
    raise ValueError("Enter 'm' or 'f'")


def parse_activity(raw):
    raw = raw.strip().lower()
    if raw not in ACTIVITY_LEVELS:
        raise ValueError(f"Choose one of: {', '.join(ACTIVITY_LEVELS)}")
    return raw


def parse_age(raw):
    try:
        age = int(raw.strip())
    except ValueError:
        raise ValueError("Age must be a whole number")
    if not 1 <= age <= 120:
        raise ValueError("Age must be between 1 and 120")
    return age


def parse_kcal(raw):
    try:
        val = float(raw.strip().lower().replace("kcal", "").replace(",", ""))
    except ValueError:
        raise ValueError("Enter calories as a number, e.g. 2000")
    if val < 0:
        raise ValueError("Calories can't be negative")
    return val


def parse_percent(raw):
    """Parse a body fat percentage like "22" or "22%"."""
    try:
        val = float(raw.strip().rstrip("%"))
    except ValueError:
        raise ValueError(f"'{raw}' isn't a number")
    if not 0 < val < 100:
        raise ValueError(f"{raw} isn't a valid body fat percentage (use 1-99)")
    return val


def kg_to_lb(kg):
    return kg * 2.20462


def cm_to_ft_in(cm):
    """Format centimeters as feet and inches, e.g. 6'5". Prefixed with ~
    when the nearest whole inch isn't an (almost) exact match."""
    total_in = cm / 2.54
    feet, inches = divmod(round(total_in), 12)
    approx = "" if abs(total_in - round(total_in)) < 0.05 else "~"
    return f"{approx}{feet}'{inches}\""


# --- CALCULATIONS -------------------------------------------------------

def calc_bmr(sex, weight_kg, height_cm, age):
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age
    return base + 5 if sex == "m" else base - 161


def calc_tdee(bmr, activity_level):
    return bmr * ACTIVITY_LEVELS[activity_level]


def calc_bodyfat(sex, waist_cm, neck_cm, height_cm, hip_cm=None):
    """U.S. Navy method, metric form. Raises ValueError if the
    measurements given don't produce a mathematically valid result
    (e.g. waist smaller than neck)."""
    if sex == "m":
        diff = waist_cm - neck_cm
        if diff <= 0:
            raise ValueError("waist must be greater than neck")
        return 495 / (1.0324 - 0.19077 * math.log10(diff) + 0.15456 * math.log10(height_cm)) - 450
    diff = waist_cm + hip_cm - neck_cm
    if diff <= 0:
        raise ValueError("waist + hip must be greater than neck")
    return 495 / (1.29579 - 0.35004 * math.log10(diff) + 0.22100 * math.log10(height_cm)) - 450


def bodyfat_category(sex, pct):
    # These published ranges use whole-percent boundaries (e.g. 14-17,
    # then 18-24) with no fractional overlap -- a raw percentage like
    # 17.4% falls in the gap between them and would hit neither range.
    # Rounding first matches how these tables are meant to be read.
    rounded = round(pct)
    for name, lo, hi in BODYFAT_CATEGORIES[sex]:
        if lo <= rounded <= hi:
            return name
    return "Obese"


# --- DATABASE -------------------------------------------------------------

def get_conn():
    os.makedirs(APP_DIR, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cols_sql = ", ".join(
        f"{f} TEXT" if f in ("sex", "activity_level")
        else f"{f} INTEGER" if f == "age"
        else f"{f} REAL"
        for f in FIELDS
    )
    conn.execute(f"""
        CREATE TABLE IF NOT EXISTS entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            {cols_sql}
        )
    """)
    return conn


def insert_entry(conn, **fields):
    """Insert a new timestamped row. Fields not passed stay NULL -- this
    is what makes each edit a partial snapshot rather than a full record."""
    now = datetime.now().isoformat(timespec="seconds")
    cols = ["timestamp"] + list(fields.keys())
    placeholders = ",".join("?" * len(cols))
    conn.execute(
        f"INSERT INTO entries ({','.join(cols)}) VALUES ({placeholders})",
        [now] + list(fields.values()),
    )
    conn.commit()


def get_latest(conn, field):
    """Most recently logged value of a single field, scanning across all
    entries (not just the literal latest row) -- the core of the
    partial-snapshot model. field is always one of the fixed FIELDS
    names above, never user input, so the f-string here is safe."""
    row = conn.execute(
        f"SELECT {field} AS v, timestamp FROM entries "
        f"WHERE {field} IS NOT NULL ORDER BY timestamp DESC, id DESC LIMIT 1"
    ).fetchone()
    return (row["v"], row["timestamp"]) if row else (None, None)


def require_profile(conn):
    sex, _ = get_latest(conn, "sex")
    height, _ = get_latest(conn, "height_cm")
    age, _ = get_latest(conn, "age")
    activity, _ = get_latest(conn, "activity_level")
    if not all([sex, height, age, activity]):
        print("[-] Profile incomplete. Run: lean --profile --edit")
        sys.exit(1)
    return sex, height, age, activity


def compute_tdee(sex, height_cm, age, activity, weight_kg):
    return calc_tdee(calc_bmr(sex, weight_kg, height_cm, age), activity)


# --- INTAKE SAFETY GUIDANCE -----------------------------------------------
# Informational only -- never blocks an entry, just surfaces where it
# falls relative to commonly-cited general guidelines. Rough deficit ->
# rate-of-weightloss math (3500 kcal =~ 1 lb) is the same estimate used
# elsewhere in this script; none of this is personalized medical advice.

def rate_to_deficit(lb_per_week):
    return lb_per_week * 3500 / 7


def nutrition_floor(sex):
    """Commonly-cited general-population minimum intake, below which
    meeting basic nutritional needs gets difficult for most people
    without medical supervision -- not an individualized figure."""
    return 1500 if sex == "m" else 1200


def deficit_guidance(tdee, sex):
    mild = tdee - rate_to_deficit(0.5)
    moderate = tdee - rate_to_deficit(1.0)
    upper = tdee - rate_to_deficit(2.0)
    floor = nutrition_floor(sex)
    # Whichever is higher protects against both failure modes: a high-TDEE
    # person's 2 lb/wk intake could sit well above the flat floor, while a
    # lower-TDEE person's could fall below it.
    effective_floor = max(upper, floor)
    return {"mild": mild, "moderate": moderate, "upper_2lb": upper,
            "nutrition_floor": floor, "effective_floor": effective_floor}


def current_tdee(conn):
    """(tdee, sex) from the latest profile + weight, or None if either is
    missing."""
    sex, _ = get_latest(conn, "sex")
    height, _ = get_latest(conn, "height_cm")
    age, _ = get_latest(conn, "age")
    activity, _ = get_latest(conn, "activity_level")
    weight, _ = get_latest(conn, "weight_kg")
    if not all([sex, height, age, activity, weight]):
        return None
    return compute_tdee(sex, height, age, activity, weight), sex


def print_intake_warning(tdee, intake, sex):
    """Prints nothing unless intake is below the general safe minimum."""
    g = deficit_guidance(tdee, sex)
    if intake < g["effective_floor"]:
        print()
        print(f"[!] This intake is below what's generally considered a safe minimum for your numbers")
        print(f"    (~{g['effective_floor']:.0f} kcal/day). Losing weight too fast risks losing muscle and")
        print(f"    bone density along with fat, not just fat. Consider a higher intake.")


# --- INPUT HELPER -------------------------------------------------------

def prompt(label, default=None, cast=str, hint=None):
    suffix = f" [{hint if hint is not None else default}]" if default is not None else ""
    while True:
        raw = input(f"{label}{suffix}: ").strip()
        if not raw and default is not None:
            return default
        if not raw:
            print("  A value is required.")
            continue
        try:
            return cast(raw)
        except ValueError as e:
            print(f"  {e}")


def prompt_log(label, current, cast, hint=None):
    """Optional prompt for a value that's logged over time. Enter skips it
    (nothing is recorded); the last logged value is shown for reference."""
    shown = f" [{hint if hint is not None else current}]" if current is not None else ""
    while True:
        raw = input(f"{label}{shown} (Enter to skip): ").strip()
        if not raw:
            return None
        try:
            return cast(raw)
        except ValueError as e:
            print(f"  {e}")


# --- EDIT HANDLERS -------------------------------------------------------

def prompt_weight_intake(conn):
    """Prompt for weight and intake; returns only the fields actually entered."""
    cur_weight, _ = get_latest(conn, "weight_kg")
    cur_intake, _ = get_latest(conn, "intake_kcal")
    fields = {}
    weight = prompt_log("Weight (e.g. 160lb or 72kg)", cur_weight,
                         lambda r: parse_mass(r, "weight"),
                         hint=f"{cur_weight:.1f}kg" if cur_weight is not None else None)
    if weight is not None:
        fields["weight_kg"] = weight
    intake = prompt_log("Calorie intake today (kcal)", cur_intake, parse_kcal,
                         hint=f"{cur_intake:.0f}" if cur_intake is not None else None)
    if intake is not None:
        fields["intake_kcal"] = intake
    return fields


def warn_if_low_intake(conn, fields):
    if "intake_kcal" not in fields:
        return
    result = current_tdee(conn)
    if result:
        print_intake_warning(result[0], fields["intake_kcal"], result[1])


def edit_profile(conn):
    cur_sex, _ = get_latest(conn, "sex")
    cur_height, _ = get_latest(conn, "height_cm")
    cur_age, _ = get_latest(conn, "age")
    cur_activity, _ = get_latest(conn, "activity_level")

    sex = prompt("Sex (m/f)", cur_sex, parse_sex)
    height = prompt("Height (e.g. 5'10\" or 178cm)", cur_height,
                     lambda r: parse_length(r, "height"),
                     hint=f"{cur_height:.1f}cm" if cur_height else None)
    age = prompt("Age", cur_age, parse_age)
    print(f"Activity levels: {', '.join(ACTIVITY_LEVELS)}")
    activity = prompt("Activity level", cur_activity, parse_activity)

    fields = dict(sex=sex, height_cm=height, age=age, activity_level=activity)
    fields.update(prompt_weight_intake(conn))
    insert_entry(conn, **fields)
    print("\n[+] Profile updated.")
    warn_if_low_intake(conn, fields)


def edit_deficit(conn):
    # Shortcut for the two inputs deficit depends on, without walking
    # through the rest of the profile.
    fields = prompt_weight_intake(conn)
    if not fields:
        print("\nNothing logged.")
        return
    insert_entry(conn, **fields)
    print("\n[+] Logged.")
    warn_if_low_intake(conn, fields)


def edit_bodyfat(conn):
    sex, _ = get_latest(conn, "sex")
    if not sex:
        print("[-] Set your profile first: lean --profile --edit")
        sys.exit(1)

    cur_neck, _ = get_latest(conn, "neck_cm")
    cur_waist, _ = get_latest(conn, "waist_cm")
    cur_hip, _ = get_latest(conn, "hip_cm")

    neck = prompt("Neck (in or cm, e.g. 15in or 38cm)", cur_neck,
                   lambda r: parse_length(r, "neck", require_unit=True),
                   hint=f"{cur_neck:.1f}cm" if cur_neck else None)
    waist = prompt("Waist (in or cm, e.g. 34in or 86cm)", cur_waist,
                    lambda r: parse_length(r, "waist", require_unit=True),
                    hint=f"{cur_waist:.1f}cm" if cur_waist else None)

    fields = dict(waist_cm=waist, neck_cm=neck)
    if sex == "f":
        fields["hip_cm"] = prompt("Hip (in or cm, e.g. 38in or 97cm)", cur_hip,
                                   lambda r: parse_length(r, "hip", require_unit=True),
                                   hint=f"{cur_hip:.1f}cm" if cur_hip else None)

    insert_entry(conn, **fields)
    print("\n[+] Measurements logged.")


# --- DISPLAY HANDLERS -----------------------------------------------------

def display_profile(conn):
    sex, _ = get_latest(conn, "sex")
    age, _ = get_latest(conn, "age")
    height, _ = get_latest(conn, "height_cm")
    weight, weight_ts = get_latest(conn, "weight_kg")
    activity, _ = get_latest(conn, "activity_level")
    intake, intake_ts = get_latest(conn, "intake_kcal")

    if not any(v is not None for v in (sex, height, age, activity, weight, intake)):
        print("No profile set yet. Run: lean --profile --edit")
        return

    print("----- Profile -----")
    print(f"Sex:             {sex or 'not set'}")
    print(f"Age:             {age if age else 'not set'}")
    print(f"Height:          {f'{height:.1f}cm ({cm_to_ft_in(height)})' if height else 'not set'}")
    print(f"Weight:          {f'{kg_to_lb(weight):.1f} lb ({weight:.1f} kg)' if weight is not None else 'not set'}")
    print(f"Intake:          {f'{intake:.0f} kcal' if intake is not None else 'not set'}")
    print(f"Activity level:  {activity or 'not set'}")


def display_weightloss(conn):
    require_profile(conn)
    result = current_tdee(conn)
    if result is None:
        print("[-] Log your weight first: lean --profile --edit")
        sys.exit(1)
    tdee, sex = result
    g = deficit_guidance(tdee, sex)
    print("----- Weightloss -----")
    print(f"TDEE:                    {tdee:.0f} kcal/day (maintenance)")
    print(f"Mild weight loss        (-0.5 lb/wk):  ~{g['mild']:.0f} kcal/day")
    print(f"Weight loss             (-1.0 lb/wk):  ~{g['moderate']:.0f} kcal/day")
    print(f"Extreme weight loss     (-2.0 lb/wk):  ~{g['upper_2lb']:.0f} kcal/day")
    intake, _ = get_latest(conn, "intake_kcal")
    if intake is not None:
        print_intake_warning(tdee, intake, sex)


def measured_bodyfat(conn):
    """(sex, body fat %) from your latest measurements, or exit with a hint."""
    sex, height, age, activity = require_profile(conn)
    waist, _ = get_latest(conn, "waist_cm")
    neck, _ = get_latest(conn, "neck_cm")
    hip, _ = get_latest(conn, "hip_cm") if sex == "f" else (None, None)

    if waist is None or neck is None or (sex == "f" and hip is None):
        print("[-] Log your measurements first: lean --bodyfat --edit")
        sys.exit(1)

    try:
        return sex, calc_bodyfat(sex, waist, neck, height, hip)
    except ValueError as e:
        print(f"[-] Measurements don't produce a valid result ({e}).")
        sys.exit(1)


def display_bodyfat(conn):
    sex, pct = measured_bodyfat(conn)
    print("----- Body Fat -----")
    print(f"Estimate:        {pct:.1f}%")
    print(f"Category:        {bodyfat_category(sex, pct)}")
    print("(Navy method estimate -- accuracy varies at extremes)")


def format_bodyfat_range(lo, hi):
    if lo <= 0:
        return f"{hi}% or less"
    if hi >= 100:
        return f"{lo}% or more"
    return f"{lo}-{hi}%"


def display_bodyfat_range(conn):
    """lean --bfp -r : body fat categories for your sex (both if no sex is
    set yet), highest to lowest, marking yours if measurements exist."""
    sex, _ = get_latest(conn, "sex")
    height, _ = get_latest(conn, "height_cm")
    waist, _ = get_latest(conn, "waist_cm")
    neck, _ = get_latest(conn, "neck_cm")
    hip, _ = get_latest(conn, "hip_cm")

    current = None  # (category, pct), only if everything needed is on file
    if sex and height and waist and neck and (sex == "m" or hip):
        try:
            pct = calc_bodyfat(sex, waist, neck, height, hip)
            current = (bodyfat_category(sex, pct), pct)
        except ValueError:
            pass

    sexes = [sex] if sex else ["m", "f"]
    for i, sx in enumerate(sexes):
        if i:
            print()
        print(f"----- Body Fat Ranges ({'male' if sx == 'm' else 'female'}) -----")
        for name, lo, hi in reversed(BODYFAT_CATEGORIES[sx]):
            line = f"{name:<15}{format_bodyfat_range(lo, hi)}"
            if current and current[0] == name:
                line += f"   <- you ({current[1]:.1f}%)"
            print(line)
    if not sex:
        print("\n(Set your sex with lean -p -e to see only your range.)")


def format_duration(weeks):
    months = weeks / (52 / 12)
    whole = max(1, round(weeks))
    return f"~{whole} week{'s' if whole != 1 else ''} (~{months:.1f} months)"


def display_bodyfat_projection(conn, values):
    """lean --bodyfat CURRENT GOAL  (or just GOAL, starting from your
    measured body fat). Assumes lean mass stays constant, so the whole
    weight change is fat, at 3500 kcal per pound."""
    weight_kg, _ = get_latest(conn, "weight_kg")
    if weight_kg is None:
        print("[-] Log your weight first: lean --profile --edit")
        sys.exit(1)
    if len(values) == 2:
        start, goal = values
    else:
        _, start = measured_bodyfat(conn)
        goal = values[0]

    if abs(goal - start) < 0.05:
        print(f"Body fat is already {start:.1f}% -- nothing to change.")
        return

    weight_lb = kg_to_lb(weight_kg)
    lean_lb = weight_lb * (1 - start / 100)
    target_lb = lean_lb / (1 - goal / 100)
    delta_lb = target_lb - weight_lb
    delta_kg = delta_lb / 2.20462
    losing = delta_lb < 0

    print("----- Body Fat Projection -----")
    print(f"Body fat:        {start:.1f}% -> {goal:.1f}%")
    print(f"Weight:          {weight_lb:.1f} lb -> {target_lb:.1f} lb")
    print(f"Fat to {'lose' if losing else 'gain'}:     {abs(delta_lb):.1f} lb ({abs(delta_kg):.1f} kg)")

    result = current_tdee(conn)
    intake, _ = get_latest(conn, "intake_kcal")
    print()
    print("Estimated time:")
    if result and intake is not None:
        tdee, sex = result
        net = tdee - intake  # positive = deficit
        if net == 0:
            print(f"  At your intake ({intake:.0f} kcal): maintenance, so no change")
        elif (net > 0) == losing:
            rate = abs(net) * 7 / 3500
            print(f"  At your intake ({intake:.0f} kcal, {rate:.2f} lb/wk): "
                  f"{format_duration(abs(delta_lb) / rate)}")
        else:
            kind = "surplus" if net < 0 else "deficit"
            print(f"  At your intake ({intake:.0f} kcal) you're in a {kind}, which moves you the other way")
    for rate in (0.5, 1.0):
        text = f"  At {rate:.1f} lb/wk"
        if result:
            tdee, sex = result
            kcal = tdee - rate_to_deficit(rate) if losing else tdee + rate_to_deficit(rate)
            text += f" (~{kcal:.0f} kcal/day)"
            if losing and kcal < nutrition_floor(sex):
                text += " [!] below the general safe minimum"
        print(f"{text}: {format_duration(abs(delta_lb) / rate)}")
    print()
    print("(Rough estimate: assumes your lean mass stays the same and 3,500 kcal = 1 lb of fat.)")


def display_deficit(conn):
    sex, height, age, activity = require_profile(conn)
    weight, _ = get_latest(conn, "weight_kg")
    intake, intake_ts = get_latest(conn, "intake_kcal")
    if weight is None or intake is None:
        print("[-] Log your weight and intake first: lean --profile --edit")
        sys.exit(1)

    tdee = compute_tdee(sex, height, age, activity, weight)
    deficit = tdee - intake
    weekly_lb = abs(deficit) * 7 / 3500

    print("----- Deficit -----")
    print(f"TDEE:            {tdee:.0f} kcal/day")
    print(f"Intake:          {intake:.0f} kcal")
    if deficit > 0:
        print(f"Deficit:         -{deficit:.0f} kcal/day")
        print(f"Est. weekly change: -{weekly_lb:.2f} lb (rough estimate)")
    elif deficit < 0:
        print(f"Surplus:         +{abs(deficit):.0f} kcal/day")
        print(f"Est. weekly change: +{weekly_lb:.2f} lb (rough estimate)")
    else:
        print("Deficit:         0 kcal/day (maintenance)")

    print_intake_warning(tdee, intake, sex)


# --- CLEAR ---------------------------------------------------------------

def confirm(question, default=False):
    raw = input(question + (" [Y/n] " if default else " [y/N] ")).strip().lower()
    return default if not raw else raw in ("y", "yes")


def prune_empty_rows(conn):
    conn.execute("DELETE FROM entries WHERE " + " AND ".join(f"{f} IS NULL" for f in FIELDS))


def clear_topic(conn, topic, assume_yes=False):
    if topic not in TOPIC_FIELDS:
        print(f"[-] {topic} is calculated from the data in your profile, so it stores nothing itself.")
        print("    To clear that data: lean --profile --edit --clear")
        sys.exit(1)
    fields = TOPIC_FIELDS[topic]
    label = TOPIC_LABELS.get(topic, topic)
    n = conn.execute(
        f"SELECT COUNT(*) FROM entries WHERE {' OR '.join(f + ' IS NOT NULL' for f in fields)}"
    ).fetchone()[0]
    if n == 0:
        print(f"Nothing stored for {topic}.")
        return
    print(f"This permanently deletes all {n} stored {label} entr{'y' if n == 1 else 'ies'}.")
    if not assume_yes and not confirm("Continue?", default=False):
        print("[!] Cancelled. Nothing was changed.")
        return
    with conn:
        conn.execute(f"UPDATE entries SET {', '.join(f + ' = NULL' for f in fields)}")
        prune_empty_rows(conn)
    print(f"[+] Cleared {topic}.")


# --- DISPATCH -------------------------------------------------------------

DISPLAY_HANDLERS = {"profile": display_profile, "bodyfat": display_bodyfat,
                     "deficit": display_deficit, "weightloss": display_weightloss}
EDIT_HANDLERS = {"profile": edit_profile, "bodyfat": edit_bodyfat,
                  "deficit": edit_deficit}
ALL_TOPICS = ("profile", "bodyfat", "deficit", "weightloss")


class BodyfatAction(argparse.Action):
    """Records "bodyfat" in the ordered topic list and keeps any percentages
    that followed the flag (e.g. --bfp 22 17)."""
    def __call__(self, parser, namespace, values, option_string=None):
        topics = list(getattr(namespace, "topics", None) or [])
        topics.append("bodyfat")
        namespace.topics = topics
        namespace.bodyfat_values = list(values)


def run_topics(topics, func):
    """Run func(topic) for each topic in order, with a blank line between.
    A topic that bails out (e.g. missing data) doesn't stop the rest; the
    exit status is 1 if any of them did."""
    status = 0
    for i, topic in enumerate(topics):
        if i:
            print()
        try:
            func(topic)
        except SystemExit as e:
            if e.code not in (None, 0):
                status = 1
    return status


def main():
    parser = argparse.ArgumentParser(
        prog="lean", description="Track calorie deficit and body fat estimates.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
Options can be combined and run in the order given.

examples:
  lean -p                  show your profile
  lean -p -e               update profile, weight and intake
  lean -p --bfp -e         edit your profile, then your body fat measurements
  lean --all               show profile, body fat, deficit and weight loss
  lean --bfp 22 17         time to go from 22% to 17% body fat
  lean --bfp -r            body fat ranges for each category
  lean -p -e -c            delete everything stored in your profile
""")
    parser.add_argument("-p", "--profile", dest="topics", action="append_const", const="profile",
                        help="sex, age, height, weight, intake, activity level")
    parser.add_argument("--bf", "--bfp", "--bodyfat", "--body-fat-percentage",
                        dest="bodyfat_values", action=BodyfatAction, nargs="*", metavar="PCT",
                        help="estimated body fat %% and category; with a goal "
                             "(--bf [CURRENT] GOAL), time to get there")
    parser.add_argument("-r", "--range", action="store_true",
                        help="with --bf, show the body fat ranges for each category (by sex)")
    parser.add_argument("-d", "--deficit", dest="topics", action="append_const", const="deficit",
                        help="today's calorie deficit/surplus (-e logs weight and intake)")
    parser.add_argument("--wl", "--weightloss", "--weight-loss", dest="topics",
                        action="append_const", const="weightloss",
                        help="TDEE and calorie weight loss targets (calculated; display only)")
    parser.add_argument("--all", dest="topics", action="append_const", const="all",
                        help="show profile, body fat, deficit and weight loss (display only)")

    parser.add_argument("-e", "--edit", action="store_true", help="update values")
    parser.add_argument("-c", "--clear", action="store_true",
                        help="delete all stored data for the topic (use with -e)")
    parser.add_argument("-y", "--yes", action="store_true", help="skip the --clear confirmation")

    args = parser.parse_args()
    requested = args.topics or []
    values = args.bodyfat_values or []

    if not requested:
        parser.error("choose what to run, e.g. -p, --bf, -d, --wl or --all")
    if args.clear and not args.edit:
        parser.error("--clear (-c) must be combined with --edit (-e)")
    if args.range:
        if "all" in requested:
            parser.error("--range (-r) can't be combined with --all")
        if "bodyfat" not in requested:
            parser.error("--range (-r) goes with --bodyfat, e.g. lean --bfp -r")
        if args.edit or args.clear:
            parser.error("--range (-r) can't be combined with --edit or --clear")
        if values:
            parser.error("--range (-r) can't be combined with body fat percentages")
    if args.edit or args.clear:
        if "all" in requested:
            parser.error("--all is display only; it can't be combined with --edit or --clear")
        if "weightloss" in requested:
            parser.error("--weightloss is calculated from your profile and weight; it can't be edited or cleared")
        if args.clear and "deficit" in requested:
            parser.error("--deficit is calculated from your profile; clear that instead: -p -e -c")
        if values:
            parser.error("--bodyfat can't take percentages together with --edit or --clear")
    if len(values) > 2:
        parser.error("--bodyfat takes at most two values: [CURRENT] GOAL")
    try:
        values = [parse_percent(v) for v in values]
    except ValueError as e:
        parser.error(str(e))

    # Expand --all, drop repeats, keep the order the options were given in.
    topics = list(dict.fromkeys(
        t for r in requested for t in (ALL_TOPICS if r == "all" else (r,))))

    def show(topic):
        if topic == "bodyfat" and args.range:
            display_bodyfat_range(conn)
        elif topic == "bodyfat" and values:
            display_bodyfat_projection(conn, values)
        else:
            DISPLAY_HANDLERS[topic](conn)

    conn = get_conn()
    status = 0
    try:
        if args.clear:
            status = run_topics(topics, lambda t: clear_topic(conn, t, args.yes))
        elif args.edit:
            status = run_topics(topics, lambda t: EDIT_HANDLERS[t](conn))
        else:
            status = run_topics(topics, show)
    except (KeyboardInterrupt, EOFError):
        print("\n[!] Cancelled.")
        sys.exit(1)
    finally:
        conn.close()
    if status:
        sys.exit(status)


if __name__ == "__main__":
    main()