/*
====================================================================
 06_etl_oltp_to_star.sql

 Purpose : Populate the dimensional model from the OLTP layer.
 Covers  : MERGE-based incremental/upsert loads, SCD Type 1 vs
           Type 2 handling, a date-dimension generator, and an
           orchestrator procedure that runs the full load in order.
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- 6.1 Populate DimDate once, for a fixed range
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadDimDate
    @StartDate DATE = '2023-01-01',
    @EndDate   DATE = '2026-12-31'
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH Dates AS (
        SELECT @StartDate AS FullDate
        UNION ALL
        SELECT DATEADD(DAY, 1, FullDate) FROM Dates WHERE FullDate < @EndDate
    )
    INSERT INTO star.DimDate (DateKey, FullDate, DayOfWeek, DayName, DayOfMonth,
                               MonthNumber, MonthName, Quarter, Year, IsWeekend)
    SELECT
        CONVERT(INT, FORMAT(FullDate, 'yyyyMMdd')),
        FullDate,
        DATEPART(WEEKDAY, FullDate),
        DATENAME(WEEKDAY, FullDate),
        DATEPART(DAY, FullDate),
        DATEPART(MONTH, FullDate),
        DATENAME(MONTH, FullDate),
        DATEPART(QUARTER, FullDate),
        DATEPART(YEAR, FullDate),
        CASE WHEN DATEPART(WEEKDAY, FullDate) IN (1,7) THEN 1 ELSE 0 END
    FROM Dates
    WHERE CONVERT(INT, FORMAT(FullDate, 'yyyyMMdd')) NOT IN (SELECT DateKey FROM star.DimDate)
    OPTION (MAXRECURSION 0);
END
GO


------------------------------------------------------------------
-- 6.2 DimCustomer - SCD Type 2 (preserve history of segment changes)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadDimCustomer
AS
BEGIN
    SET NOCOUNT ON;

    -- Step 1: expire rows whose segment has changed
    UPDATE dc
    SET dc.ExpiryDate = CAST(SYSDATETIME() AS DATE), dc.IsCurrent = 0
    FROM star.DimCustomer dc
    JOIN oltp.Customers c ON c.CustomerID = dc.CustomerID
    WHERE dc.IsCurrent = 1
      AND dc.CustomerSegment <> c.CustomerSegment;

    -- Step 2: insert new customers AND new versions of changed customers
    INSERT INTO star.DimCustomer (CustomerID, FullName, Email, CustomerSegment,
                                   SignupDate, EffectiveDate, ExpiryDate, IsCurrent)
    SELECT
        c.CustomerID,
        CONCAT(c.FirstName, ' ', c.LastName),
        c.Email,
        c.CustomerSegment,
        c.SignupDate,
        CAST(SYSDATETIME() AS DATE),
        NULL,
        1
    FROM oltp.Customers c
    WHERE NOT EXISTS (
        SELECT 1 FROM star.DimCustomer dc
        WHERE dc.CustomerID = c.CustomerID AND dc.IsCurrent = 1
    );
END
GO


------------------------------------------------------------------
-- 6.3 DimProduct - SCD Type 1 (overwrite in place via MERGE)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadDimProduct
AS
BEGIN
    SET NOCOUNT ON;

    MERGE star.DimProduct AS tgt
    USING (
        SELECT p.ProductID, p.ProductName, cat.CategoryName, s.SupplierName,
               p.UnitPrice, p.Discontinued
        FROM oltp.Products p
        JOIN oltp.Categories cat ON cat.CategoryID = p.CategoryID
        JOIN oltp.Suppliers s ON s.SupplierID = p.SupplierID
    ) AS src
    ON tgt.ProductID = src.ProductID
    WHEN MATCHED AND (tgt.UnitPrice <> src.UnitPrice OR tgt.Discontinued <> src.Discontinued
                        OR tgt.CategoryName <> src.CategoryName) THEN
        UPDATE SET ProductName = src.ProductName, CategoryName = src.CategoryName,
                   SupplierName = src.SupplierName, UnitPrice = src.UnitPrice,
                   Discontinued = src.Discontinued
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (ProductID, ProductName, CategoryName, SupplierName, UnitPrice, Discontinued)
        VALUES (src.ProductID, src.ProductName, src.CategoryName, src.SupplierName,
                src.UnitPrice, src.Discontinued);
END
GO


------------------------------------------------------------------
-- 6.4 DimEmployee, DimGeography - simple MERGE upserts
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadDimEmployee
AS
BEGIN
    SET NOCOUNT ON;
    MERGE star.DimEmployee AS tgt
    USING (SELECT EmployeeID, CONCAT(FirstName,' ',LastName) AS FullName, Title, Region
           FROM oltp.Employees) AS src
    ON tgt.EmployeeID = src.EmployeeID
    WHEN MATCHED THEN UPDATE SET FullName = src.FullName, Title = src.Title, Region = src.Region
    WHEN NOT MATCHED THEN INSERT (EmployeeID, FullName, Title, Region)
        VALUES (src.EmployeeID, src.FullName, src.Title, src.Region);
END
GO

CREATE OR ALTER PROCEDURE star.usp_ETL_LoadDimGeography
AS
BEGIN
    SET NOCOUNT ON;
    MERGE star.DimGeography AS tgt
    USING (SELECT DISTINCT City, State, Country FROM oltp.ShippingAddresses) AS src
    ON tgt.City = src.City AND tgt.State = src.State AND tgt.Country = src.Country
    WHEN NOT MATCHED THEN INSERT (City, State, Country) VALUES (src.City, src.State, src.Country);
END
GO


------------------------------------------------------------------
-- 6.5 FactSales - transactional grain, incremental via MERGE on
--     the natural key (OrderDetailID)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadFactSales
AS
BEGIN
    SET NOCOUNT ON;

    MERGE star.FactSales AS tgt
    USING (
        SELECT
            od.OrderDetailID,
            CONVERT(INT, FORMAT(o.OrderDate, 'yyyyMMdd')) AS DateKey,
            dc.CustomerKey,
            dp.ProductKey,
            de.EmployeeKey,
            dg.GeographyKey,
            od.Quantity, od.UnitPrice, od.Discount, od.LineTotal
        FROM oltp.OrderDetails od
        JOIN oltp.Orders o        ON o.OrderID = od.OrderID
        JOIN oltp.ShippingAddresses a ON a.AddressID = o.AddressID
        JOIN star.DimCustomer dc  ON dc.CustomerID = o.CustomerID AND dc.IsCurrent = 1
        JOIN star.DimProduct dp   ON dp.ProductID = od.ProductID
        LEFT JOIN star.DimEmployee de ON de.EmployeeID = o.EmployeeID
        JOIN star.DimGeography dg ON dg.City = a.City AND dg.State = a.State AND dg.Country = a.Country
    ) AS src
    ON tgt.OrderDetailID = src.OrderDetailID
    WHEN MATCHED THEN
        UPDATE SET Quantity = src.Quantity, UnitPrice = src.UnitPrice,
                   Discount = src.Discount, LineTotal = src.LineTotal
    WHEN NOT MATCHED THEN
        INSERT (OrderDetailID, DateKey, CustomerKey, ProductKey, EmployeeKey, GeographyKey,
                Quantity, UnitPrice, Discount, LineTotal)
        VALUES (src.OrderDetailID, src.DateKey, src.CustomerKey, src.ProductKey, src.EmployeeKey,
                src.GeographyKey, src.Quantity, src.UnitPrice, src.Discount, src.LineTotal);
END
GO


------------------------------------------------------------------
-- 6.6 FactInventorySnapshot - periodic snapshot, one row per
--     product for "today" (run this daily in production)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_LoadFactInventorySnapshot
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TodayKey INT = CONVERT(INT, FORMAT(SYSDATETIME(), 'yyyyMMdd'));

    MERGE star.FactInventorySnapshot AS tgt
    USING (
        SELECT @TodayKey AS DateKey, dp.ProductKey, i.QuantityOnHand, p.ReorderLevel
        FROM oltp.Inventory i
        JOIN oltp.Products p ON p.ProductID = i.ProductID
        JOIN star.DimProduct dp ON dp.ProductID = i.ProductID
    ) AS src
    ON tgt.DateKey = src.DateKey AND tgt.ProductKey = src.ProductKey
    WHEN MATCHED THEN UPDATE SET QuantityOnHand = src.QuantityOnHand, ReorderLevel = src.ReorderLevel
    WHEN NOT MATCHED THEN
        INSERT (DateKey, ProductKey, QuantityOnHand, ReorderLevel)
        VALUES (src.DateKey, src.ProductKey, src.QuantityOnHand, src.ReorderLevel);
END
GO


------------------------------------------------------------------
-- 6.7 Orchestrator: run the full load in dependency order,
--     logging each step (mirrors a real load_audit_log pattern)
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE star.usp_ETL_RunFullLoad
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Step NVARCHAR(100);

    BEGIN TRY
        SET @Step = 'DimDate';       EXEC star.usp_ETL_LoadDimDate;
        SET @Step = 'DimCustomer';   EXEC star.usp_ETL_LoadDimCustomer;
        SET @Step = 'DimProduct';    EXEC star.usp_ETL_LoadDimProduct;
        SET @Step = 'DimEmployee';   EXEC star.usp_ETL_LoadDimEmployee;
        SET @Step = 'DimGeography';  EXEC star.usp_ETL_LoadDimGeography;
        SET @Step = 'FactSales';     EXEC star.usp_ETL_LoadFactSales;
        SET @Step = 'FactInventory'; EXEC star.usp_ETL_LoadFactInventorySnapshot;

        PRINT 'Full ETL load completed successfully.';
    END TRY
    BEGIN CATCH
        INSERT INTO audit.ErrorLog (ErrorProcedure, ErrorNumber, ErrorMessage)
        VALUES (CONCAT('usp_ETL_RunFullLoad - failed at step: ', @Step), ERROR_NUMBER(), ERROR_MESSAGE());
        THROW;
    END CATCH
END
GO

-- Run the whole thing:
-- EXEC star.usp_ETL_RunFullLoad;

PRINT 'ETL procedures created.';
