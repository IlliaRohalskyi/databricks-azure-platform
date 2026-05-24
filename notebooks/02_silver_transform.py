from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, TimestampType


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

bronze_path = f"abfss://bronze@{storage_account}.dfs.core.windows.net/sensors/"
silver_path = f"abfss://silver@{storage_account}.dfs.core.windows.net/sensors/"

df = spark.read.format("delta").load(bronze_path)

df_clean = (
    df.withColumn("temperature_celsius", F.col("temperature_celsius").cast(DoubleType()))
    .withColumn("vibration_ms2", F.col("vibration_ms2").cast(DoubleType()))
    .withColumn("pressure_bar", F.col("pressure_bar").cast(DoubleType()))
    .withColumn("timestamp", F.col("timestamp").cast(TimestampType()))
    .dropDuplicates(["machine_id", "timestamp"])
    .filter(F.col("temperature_celsius").isNotNull())
    .filter(F.col("machine_id").isNotNull())
    .withColumn("processed_at", F.current_timestamp())
)

df_clean.write.format("delta").mode("overwrite").option("overwriteSchema", True).save(silver_path)
print(f"Silver: {df_clean.count()} rows after cleaning")