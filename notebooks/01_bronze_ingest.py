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

raw_path = f"abfss://raw-data@{storage_account}.dfs.core.windows.net/sensor_data_raw.csv"
bronze_path = f"abfss://bronze@{storage_account}.dfs.core.windows.net/sensors/"

df_raw = spark.read.option("header", True).csv(raw_path)

df_bronze = (
    df_raw.withColumn("ingested_at", F.current_timestamp())
    .withColumn("source_file", F.lit("sensor_data_raw.csv"))
)

df_bronze.write.format("delta").mode("append").save(bronze_path)
print(f"Bronze: {df_bronze.count()} rows written")