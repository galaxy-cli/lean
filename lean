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
# reference are calculated from other data, so they own none.
TOPIC_FIELDS = {
    "profile": ["sex", "height_cm", "age", "activity_level"],
    "weight": ["weight_kg"],
    "intake": ["intake_kcal"],
    "bodyfat": ["waist_cm", "neck_cm", "hip_cm"],
}


# --- UNIT PARSING -----------------------------------------------------
# Kept deliberately simple for a first draft: lengths default to cm when
# no unit is given, mass defaults to lb (matching how most people in
# practice think of body weight) -- documented via the prompt hints.

def parse_length(raw, label):
    """Parse a height/circumference measurement into centimeters.
    Accepts "178cm", "70in", "5'10\"", or a bare number (assumed cm)."""
    raw = raw.strip().lower()
    m = re.match(r"^(\d+)'\s*(\d+(?:\.\d+)?)\"?$", raw)
    if m:
        feet, inches = float(m.group(1)), float(m.group(2))
        return (feet * 12 + inches) * 2.54
    m = re.match(r"^([\d.]+)\s*(cm|in|inch|inches)?$", raw)
    if m:
        val = float(m.group(1))
        unit = m.group(2) or "cm"
        return val * 2.54 if unit.startswith("in") else val
    raise ValueError(f"Could not parse {label} -- try e.g. 178cm or 5'10\"")


def parse_mass(raw, label):
    """Parse a weight measurement into kilograms.
    Accepts "72kg", "160lb", "160lbs", or a bare number (assumed lb)."""
    raw = raw.strip().lower()
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


def kg_to_lb(kg):
    return kg * 2.20462


def cm_to_in(cm):
    return cm / 2.54


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
# rate-of-loss math (3500 kcal =~ 1 lb) is the same estimate used
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


# --- EDIT HANDLERS -------------------------------------------------------

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

    insert_entry(conn, sex=sex, height_cm=height, age=age, activity_level=activity)
    print("\n[+] Profile updated.")


def edit_weight(conn):
    cur_weight, _ = get_latest(conn, "weight_kg")
    weight = prompt("Weight (e.g. 160lb or 72kg)", cur_weight,
                     lambda r: parse_mass(r, "weight"),
                     hint=f"{cur_weight:.1f}kg" if cur_weight else None)
    insert_entry(conn, weight_kg=weight)
    print("\n[+] Weight logged.")


def edit_intake(conn):
    cur_intake, _ = get_latest(conn, "intake_kcal")
    intake = prompt("Calorie intake today (kcal)", cur_intake, parse_kcal,
                     hint=f"{cur_intake:.0f}" if cur_intake else None)
    insert_entry(conn, intake_kcal=intake)
    print("\n[+] Intake logged.")
    result = current_tdee(conn)
    if result:
        print_intake_warning(result[0], intake, result[1])


def edit_deficit(conn):
    # deficit has no inputs of its own -- it's weight and intake together.
    edit_weight(conn)
    edit_intake(conn)


def edit_bodyfat(conn):
    sex, _ = get_latest(conn, "sex")
    if not sex:
        print("[-] Set your profile first: lean --profile --edit")
        sys.exit(1)

    cur_waist, _ = get_latest(conn, "waist_cm")
    cur_neck, _ = get_latest(conn, "neck_cm")
    cur_hip, _ = get_latest(conn, "hip_cm")

    waist = prompt("Waist (e.g. 34in or 86cm)", cur_waist,
                    lambda r: parse_length(r, "waist"),
                    hint=f"{cur_waist:.1f}cm" if cur_waist else None)
    neck = prompt("Neck (e.g. 15in or 38cm)", cur_neck,
                   lambda r: parse_length(r, "neck"),
                   hint=f"{cur_neck:.1f}cm" if cur_neck else None)

    fields = dict(waist_cm=waist, neck_cm=neck)
    if sex == "f":
        fields["hip_cm"] = prompt("Hip (e.g. 38in or 97cm)", cur_hip,
                                   lambda r: parse_length(r, "hip"),
                                   hint=f"{cur_hip:.1f}cm" if cur_hip else None)

    insert_entry(conn, **fields)
    print("\n[+] Measurements logged.")


# --- DISPLAY HANDLERS -----------------------------------------------------

def display_profile(conn):
    sex, _ = get_latest(conn, "sex")
    height, _ = get_latest(conn, "height_cm")
    age, _ = get_latest(conn, "age")
    activity, _ = get_latest(conn, "activity_level")

    if not any([sex, height, age, activity]):
        print("No profile set yet. Run: lean --profile --edit")
        return

    print("----- Profile -----")
    print(f"Sex:             {sex or 'not set'}")
    print(f"Height:          {f'{height:.1f}cm ({cm_to_in(height):.1f}in)' if height else 'not set'}")
    print(f"Age:             {age if age else 'not set'}")
    print(f"Activity level:  {activity or 'not set'}")


def display_weight(conn):
    weight, weight_ts = get_latest(conn, "weight_kg")
    if weight is None:
        print("No weight logged yet. Run: lean --weight --edit")
        return
    print("----- Weight -----")
    print(f"{kg_to_lb(weight):.1f} lb ({weight:.1f} kg) as of {weight_ts[:10]}")


def display_intake(conn):
    intake, intake_ts = get_latest(conn, "intake_kcal")
    if intake is None:
        print("No intake logged yet. Run: lean --intake --edit")
        return
    print("----- Intake -----")
    print(f"{intake:.0f} kcal (as of {intake_ts[:10]})")


def display_reference(conn):
    require_profile(conn)
    result = current_tdee(conn)
    if result is None:
        print("[-] Log your weight first: lean --weight --edit")
        sys.exit(1)
    tdee, sex = result
    g = deficit_guidance(tdee, sex)
    print("----- Reference -----")
    print(f"TDEE:                    {tdee:.0f} kcal/day (maintenance)")
    print(f"Mild weight loss        (-0.5 lb/wk):  ~{g['mild']:.0f} kcal/day")
    print(f"Weight loss             (-1.0 lb/wk):  ~{g['moderate']:.0f} kcal/day")
    print(f"Extreme weight loss     (-2.0 lb/wk):  ~{g['upper_2lb']:.0f} kcal/day")
    print(f"Safe minimum for you:    ~{g['effective_floor']:.0f} kcal/day")
    intake, _ = get_latest(conn, "intake_kcal")
    if intake is not None:
        print_intake_warning(tdee, intake, sex)


def display_bodyfat(conn):
    sex, height, age, activity = require_profile(conn)
    waist, _ = get_latest(conn, "waist_cm")
    neck, _ = get_latest(conn, "neck_cm")
    hip, _ = get_latest(conn, "hip_cm") if sex == "f" else (None, None)

    if waist is None or neck is None or (sex == "f" and hip is None):
        print("[-] Log your measurements first: lean --bodyfat --edit")
        sys.exit(1)

    try:
        pct = calc_bodyfat(sex, waist, neck, height, hip)
    except ValueError as e:
        print(f"[-] Measurements don't produce a valid result ({e}).")
        sys.exit(1)

    print("----- Body Fat -----")
    print(f"Estimate:        {pct:.1f}%")
    print(f"Category:        {bodyfat_category(sex, pct)}")
    print("(Navy method estimate -- accuracy varies at extremes)")


def display_deficit(conn):
    sex, height, age, activity = require_profile(conn)
    weight, _ = get_latest(conn, "weight_kg")
    intake, intake_ts = get_latest(conn, "intake_kcal")
    if weight is None or intake is None:
        print("[-] Log your weight and intake first: lean --weight --edit, lean --intake --edit")
        sys.exit(1)

    tdee = compute_tdee(sex, height, age, activity, weight)
    deficit = tdee - intake
    weekly_lb = abs(deficit) * 7 / 3500

    print("----- Deficit -----")
    print(f"TDEE:            {tdee:.0f} kcal/day")
    print(f"Intake:          {intake:.0f} kcal (as of {intake_ts[:10]})")
    if deficit > 0:
        print(f"Deficit:         {deficit:.0f} kcal/day")
        print(f"Est. weekly change: -{weekly_lb:.2f} lb (rough estimate)")
    elif deficit < 0:
        print(f"Surplus:         {abs(deficit):.0f} kcal/day")
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
    if topic == "deficit":
        print("[-] deficit is calculated from weight and intake, so it stores nothing itself.")
        print("    Clear those instead: lean --weight --edit --clear / lean --intake --edit --clear")
        sys.exit(1)
    fields = TOPIC_FIELDS[topic]
    n = conn.execute(
        f"SELECT COUNT(*) FROM entries WHERE {' OR '.join(f + ' IS NOT NULL' for f in fields)}"
    ).fetchone()[0]
    if n == 0:
        print(f"Nothing stored for {topic}.")
        return
    print(f"This permanently deletes all {n} stored {topic} entr{'y' if n == 1 else 'ies'}.")
    if not assume_yes and not confirm("Continue?", default=False):
        print("[!] Cancelled. Nothing was changed.")
        return
    with conn:
        conn.execute(f"UPDATE entries SET {', '.join(f + ' = NULL' for f in fields)}")
        prune_empty_rows(conn)
    print(f"[+] Cleared {topic}.")


# --- DISPATCH -------------------------------------------------------------

DISPLAY_HANDLERS = {"profile": display_profile, "weight": display_weight,
                     "intake": display_intake, "bodyfat": display_bodyfat,
                     "deficit": display_deficit, "reference": display_reference}
EDIT_HANDLERS = {"profile": edit_profile, "weight": edit_weight,
                  "intake": edit_intake, "bodyfat": edit_bodyfat,
                  "deficit": edit_deficit}
TOPICS = tuple(DISPLAY_HANDLERS)


def main():
    parser = argparse.ArgumentParser(
        prog="lean", description="Track calorie deficit and body fat estimates.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""\
examples:
  lean --weight                  show current weight
  lean --weight --edit           log a new weight
  lean --weight --edit --clear   delete everything stored for a topic
  lean --reference               TDEE and calorie reference points
""")
    topic = parser.add_mutually_exclusive_group(required=True)
    topic.add_argument("--profile", action="store_true", help="sex, height, age, activity level")
    topic.add_argument("--weight", action="store_true", help="current weight")
    topic.add_argument("--intake", action="store_true", help="daily calorie intake")
    topic.add_argument("--bodyfat", action="store_true", help="estimated body fat %% and category")
    topic.add_argument("--deficit", action="store_true", help="today's calorie deficit/surplus")
    topic.add_argument("--reference", action="store_true",
                       help="TDEE and calorie reference points (calculated; display only)")

    parser.add_argument("--edit", action="store_true", help="update values")
    parser.add_argument("--clear", action="store_true",
                        help="delete all stored data for the topic (use with --edit)")
    parser.add_argument("-y", "--yes", action="store_true", help="skip the --clear confirmation")

    args = parser.parse_args()
    if args.clear and not args.edit:
        parser.error("--clear must be combined with --edit")
    if args.reference and (args.edit or args.clear):
        parser.error("--reference is calculated from your profile and weight; it can't be edited or cleared")
    topic_name = next(t for t in TOPICS if getattr(args, t))

    conn = get_conn()
    try:
        if args.clear:
            clear_topic(conn, topic_name, args.yes)
        elif args.edit:
            EDIT_HANDLERS[topic_name](conn)
        else:
            DISPLAY_HANDLERS[topic_name](conn)
    except (KeyboardInterrupt, EOFError):
        print("\n[!] Cancelled.")
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()