/*
====================================================================
 02_create_star_schema.sql

 Purpose : Dimensional model fed from the OLTP layer.
 Covers  : Star schema design, surrogate keys, SCD Type 1/2 columns,
           three fact-table grains (transactional, periodic snapshot,
           accumulating snapshot).
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- DimDate: standard date dimension, pre-populated by script 06
------------------------------------------------------------------
CREATE TABLE star.DimDate (
    DateKey         INT             PRIMARY KEY,        -- yyyymmdd
    FullDate        DATE            NOT NULL,
    DayOfWeek       TINYINT         NOT NULL,
    DayName         VARCHAR(10)     NOT NULL,
    DayOfMonth      TINYINT         NOT NULL,
    MonthNumber     TINYINT         NOT NULL,
    MonthName       VARCHAR(10)     NOT NULL,
    Quarter         TINYINT         NOT NULL,
    Year            SMALLINT        NOT NULL,
    IsWeekend       BIT             NOT NULL
);

------------------------------------------------------------------
-- DimCustomer: SCD Type 2 (tracks history of segment changes)
------------------------------------------------------------------
CREATE TABLE star.DimCustomer (
    CustomerKey     INT IDENTITY(1,1) PRIMARY KEY,      -- surrogate key
    CustomerID      INT             NOT NULL,           -- natural/business key
    FullName        NVARCHAR(120)   NOT NULL,
    Email           NVARCHAR(150)   NOT NULL,
    CustomerSegment VARCHAR(20)     NOT NULL,
    SignupDate      DATE            NOT NULL,
    EffectiveDate   DATE            NOT NULL,
    ExpiryDate      DATE            NULL,
    IsCurrent       BIT             NOT NULL DEFAULT 1
);

------------------------------------------------------------------
-- DimProduct: SCD Type 1 (overwrite on change - price/category corrections)
------------------------------------------------------------------
CREATE TABLE star.DimProduct (
    ProductKey      INT IDENTITY(1,1) PRIMARY KEY,
    ProductID       INT             NOT NULL,
    ProductName     NVARCHAR(150)   NOT NULL,
    CategoryName    NVARCHAR(100)   NOT NULL,
    SupplierName    NVARCHAR(150)   NOT NULL,
    UnitPrice       DECIMAL(10,2)   NOT NULL,
    Discontinued    BIT             NOT NULL
);

------------------------------------------------------------------
-- DimEmployee, DimGeography
------------------------------------------------------------------
CREATE TABLE star.DimEmployee (
    EmployeeKey     INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID      INT             NOT NULL,
    FullName        NVARCHAR(120)   NOT NULL,
    Title           NVARCHAR(80)    NOT NULL,
    Region          NVARCHAR(60)    NOT NULL
);

CREATE TABLE star.DimGeography (
    GeographyKey    INT IDENTITY(1,1) PRIMARY KEY,
    City            NVARCHAR(80)    NOT NULL,
    State           NVARCHAR(80)    NOT NULL,
    Country         NVARCHAR(80)    NOT NULL,
    CONSTRAINT UQ_Geography UNIQUE (City, State, Country)
);

------------------------------------------------------------------
-- FactSales: transactional grain (one row per order line)
------------------------------------------------------------------
CREATE TABLE star.FactSales (
    SalesKey        BIGINT IDENTITY(1,1) PRIMARY KEY,
    OrderDetailID   INT             NOT NULL,           -- natural key back to OLTP, used for MERGE
    DateKey         INT             NOT NULL REFERENCES star.DimDate(DateKey),
    CustomerKey     INT             NOT NULL REFERENCES star.DimCustomer(CustomerKey),
    ProductKey      INT             NOT NULL REFERENCES star.DimProduct(ProductKey),
    EmployeeKey     INT             NULL REFERENCES star.DimEmployee(EmployeeKey),
    GeographyKey    INT             NOT NULL REFERENCES star.DimGeography(GeographyKey),
    Quantity        INT             NOT NULL,
    UnitPrice       DECIMAL(10,2)   NOT NULL,
    Discount        DECIMAL(4,2)    NOT NULL,
    LineTotal       DECIMAL(12,2)   NOT NULL,
    LoadedAt        DATETIME2       NOT NULL DEFAULT SYSDATETIME()
);
CREATE INDEX IX_FactSales_DateKey ON star.FactSales(DateKey);
CREATE INDEX IX_FactSales_CustomerKey ON star.FactSales(CustomerKey);
CREATE INDEX IX_FactSales_ProductKey ON star.FactSales(ProductKey);

------------------------------------------------------------------
-- FactInventorySnapshot: periodic snapshot grain (one row per product per day)
------------------------------------------------------------------
CREATE TABLE star.FactInventorySnapshot (
    SnapshotKey     BIGINT IDENTITY(1,1) PRIMARY KEY,
    DateKey         INT             NOT NULL REFERENCES star.DimDate(DateKey),
    ProductKey      INT             NOT NULL REFERENCES star.DimProduct(ProductKey),
    QuantityOnHand  INT             NOT NULL,
    ReorderLevel    INT             NOT NULL,
    LoadedAt        DATETIME2       NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT UQ_InventorySnapshot UNIQUE (DateKey, ProductKey)
);

------------------------------------------------------------------
-- FactReturns: accumulating snapshot grain (one row per return, updated as it's processed)
------------------------------------------------------------------
CREATE TABLE star.FactReturns (
    ReturnKey           BIGINT IDENTITY(1,1) PRIMARY KEY,
    ReturnID            INT         NOT NULL,
    OrderDateKey        INT         NOT NULL REFERENCES star.DimDate(DateKey),
    ReturnDateKey       INT         NOT NULL REFERENCES star.DimDate(DateKey),
    RefundDateKey       INT         NULL REFERENCES star.DimDate(DateKey),
    CustomerKey         INT         NOT NULL REFERENCES star.DimCustomer(CustomerKey),
    ProductKey          INT         NOT NULL REFERENCES star.DimProduct(ProductKey),
    QuantityReturned    INT         NOT NULL,
    RefundAmount        DECIMAL(12,2) NOT NULL,
    DaysToRefund        AS (DATEDIFF(DAY, CONVERT(DATE,CAST(ReturnDateKey as CHAR(8)),112),
								   CONVERT(DATE,CAST(NULLIF(RefundDateKey,0) as CHAR(8)),112))) PERSISTED 
);
GO

PRINT 'Star schema created successfully.';
