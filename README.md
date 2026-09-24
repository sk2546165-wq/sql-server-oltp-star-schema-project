# RetailFlow — MS SQL Server Order Management & Analytics Platform

An end-to-end MS SQL Server project built to demonstrate the full range of
T-SQL skills, from schema design through transaction-safe business logic
to a dimensional reporting layer.

## Why this project

Most portfolio SQL projects are either "toy" reporting queries against a
sample database, or a dimensional model with no OLTP logic behind it.
RetailFlow does both: a normalized transactional database that a real
retail order system would run on, **plus** a star-schema layer built from
it for BI tools (Power BI / Tableau).

## Architecture

```
oltp.*   → normalized (3NF) transactional tables: Customers, Products,
           Orders, OrderDetails, Payments, Inventory, Returns, etc.
star.*   → dimensional model: DimDate, DimCustomer (SCD2), DimProduct (SCD1),
           DimEmployee, DimGeography, FactSales, FactInventorySnapshot,
           FactReturns
audit.*  → OrderAuditLog, ErrorLog — written to by triggers and procedures
```

## Run order

| # | Script | What it does |
|---|--------|---------------|
| 01 | `01_create_database_oltp.sql` | Creates the database and OLTP schema |
| 02 | `02_create_star_schema.sql` | Creates the dimensional model |
| 03 | `03_insert_sample_data.sql` | Loads ~500 customers, 24 products, ~6,000 orders, ~15,000 order lines |
| 04 | `04_transactions_and_error_handling.sql` | `usp_PlaceOrder`, `usp_ProcessReturn`, isolation-level and deadlock demos |
| 05 | `05_stored_procedures_triggers.sql` | Functions, triggers, dynamic SQL, DCL/roles |
| 06 | `06_etl_oltp_to_star.sql` | MERGE-based ETL from OLTP into the star schema |
| 07 | `07_advanced_queries_window_functions.sql` | Analytical query showcase |

After running 01–03, execute `EXEC star.usp_ETL_RunFullLoad;` to populate
the star schema, then run the queries in script 07 against it.

## Concepts demonstrated

- **Schema design**: normalization to 3NF, star schema with three fact
  grains (transactional, periodic snapshot, accumulating snapshot),
  surrogate vs. natural keys, computed/persisted columns
- **Transactions**: `BEGIN TRAN/COMMIT/ROLLBACK`, `TRY...CATCH`,
  `XACT_ABORT`, `XACT_STATE()`, `SAVE TRANSACTION` for partial rollback,
  row locking hints (`UPDLOCK`, `ROWLOCK`) to prevent overselling stock
- **Concurrency**: isolation-level comparison (dirty reads under
  `READ UNCOMMITTED`), a reproducible deadlock scenario and its fix
- **Programmability**: scalar & table-valued functions, `AFTER` and
  `INSTEAD OF` triggers, `RAISERROR`/`THROW`, parameterized dynamic SQL
- **ETL**: `MERGE`-based upserts, SCD Type 1 (products) and Type 2
  (customers) handling, an orchestrator procedure with step-level
  error logging
- **Analytics**: window functions (running totals, `RANK`, `LAG`),
  recursive CTEs, `PIVOT`, gaps-and-islands, set operators
- **Security**: reporting role with least-privilege grants for a BI
  connection

## Suggested next step

Point Power BI or Tableau at the `star` schema tables for a reporting
layer on top — this reuses the same Power BI/DAX approach from the
Sales Analytics and HR Analytics projects, closing the loop from raw
transactional data to dashboard.

## LinkedIn blurb

> Designed and built RetailFlow, an end-to-end MS SQL Server project:
> a normalized order-management database with transaction-safe stored
> procedures (ACID compliance, isolation levels, deadlock handling),
> feeding a star-schema reporting layer via MERGE-based ETL — covering
> the full range of T-SQL from schema design to window functions.
