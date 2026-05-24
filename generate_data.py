from __future__ import annotations

import random
from datetime import datetime, timedelta

import pandas as pd


def build_sensor_data(machine_count: int = 10, readings_per_machine: int = 500) -> pd.DataFrame:
    machines = [f"MACHINE_{index:03d}" for index in range(1, machine_count + 1)]
    records: list[dict[str, object]] = []

    for machine in machines:
        for reading_index in range(readings_per_machine):
            timestamp = datetime(2026, 1, 1) + timedelta(minutes=reading_index * 5)
            records.append(
                {
                    "machine_id": machine,
                    "timestamp": timestamp.isoformat(),
                    "temperature_celsius": round(random.gauss(75, 10), 2),
                    "vibration_ms2": round(random.gauss(2.5, 0.8), 3),
                    "pressure_bar": round(random.gauss(5.0, 0.5), 2),
                    "status": random.choice(["OK", "OK", "OK", "WARN", "ERROR"]),
                }
            )

    frame = pd.DataFrame(records)

    frame.loc[frame.sample(frac=0.03, random_state=7).index, "temperature_celsius"] = None
    frame.loc[frame.sample(frac=0.02, random_state=13).index, "vibration_ms2"] = None
    frame = pd.concat([frame, frame.sample(50, random_state=21)], ignore_index=True)
    frame.loc[frame.sample(10, random_state=42).index, "temperature_celsius"] = 200.0

    return frame


def main() -> None:
    sensor_data = build_sensor_data()
    sensor_data.to_csv("sensor_data_raw.csv", index=False)
    print(f"Wrote {len(sensor_data)} rows to sensor_data_raw.csv")


if __name__ == "__main__":
    main()