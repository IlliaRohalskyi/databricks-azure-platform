from pyspark.sql import functions as F


dbutils.widgets.text("storage_account", "")
storage_account = dbutils.widgets.get("storage_account").strip()
if not storage_account:
    raise ValueError("Missing required ADF parameter: storage_account")
dbutils.widgets.text("storage_key", "")
storage_key = dbutils.widgets.get("storage_key").strip()
if not storage_key:
    raise ValueError("Missing required ADF parameter: storage_key")

spark.conf.set(
    f"fs.azure.account.key.{storage_account}.dfs.core.windows.net",
    storage_key,
)

silver_path = f"abfss://silver@{storage_account}.dfs.core.windows.net/sensors/"
gold_path = f"abfss://gold@{storage_account}.dfs.core.windows.net/machine_hourly_metrics/"

df = spark.read.format("delta").load(silver_path)

df_gold = (
    df.withColumn("hour", F.date_trunc("hour", F.col("timestamp")))
    .groupBy("machine_id", "hour")
    .agg(
        F.avg("temperature_celsius").alias("avg_temp"),
        F.max("temperature_celsius").alias("max_temp"),
        F.avg("vibration_ms2").alias("avg_vibration"),
        F.avg("pressure_bar").alias("avg_pressure"),
        F.count("*").alias("reading_count"),
        F.sum(F.when(F.col("status") == "ERROR", 1).otherwise(0)).alias("error_count"),
    )
    .withColumn("anomaly_flag", F.col("max_temp") > F.lit(150.0))
    .withColumn("aggregated_at", F.current_timestamp())
)

df_gold.write.format("delta").mode("overwrite").save(gold_path)
print(f"Gold: {df_gold.count()} aggregated rows")