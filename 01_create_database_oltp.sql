/*
====================================================================
 RetailFlow - Order Management & Fulfillment System
 01_create_database_oltp.sql

 Purpose : Create the database and the normalized (3NF) OLTP layer.
 Covers  : DDL, data types, PK/FK/CHECK/UNIQUE/DEFAULT constraints,
           schemas for logical separation.
====================================================================
*/

IF DB_ID('RetailFlowDB') IS NULL
BEGIN
    CREATE DATABASE RetailFlowDB;
END
GO

USE RetailFlowDB;
GO

-- Logical schemas: oltp = transactional tables, star = dimensional model, audit = logging
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'oltp')
    EXEC('CREATE SCHEMA oltp');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'star')
    EXEC('CREATE SCHEMA star');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit')
    EXEC('CREATE SCHEMA audit');
GO

------------------------------------------------------------------
-- Reference / lookup tables
------------------------------------------------------------------
CREATE TABLE oltp.Categories (
    CategoryID      INT IDENTITY(1,1) PRIMARY KEY,
    CategoryName    NVARCHAR(100)   NOT NULL UNIQUE,
    Description     NVARCHAR(400)   NULL
);

CREATE TABLE oltp.Suppliers (
    SupplierID      INT IDENTITY(1,1) PRIMARY KEY,
    SupplierName    NVARCHAR(150)   NOT NULL,
    ContactEmail    NVARCHAR(150)   NULL,
    Phone           VARCHAR(20)     NULL,
    Country         NVARCHAR(80)    NOT NULL,
    CreatedAt       DATETIME2       NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE oltp.Employees (
    EmployeeID      INT IDENTITY(1,1) PRIMARY KEY,
    FirstName       NVARCHAR(60)    NOT NULL,
    LastName        NVARCHAR(60)    NOT NULL,
    ManagerID       INT             NULL REFERENCES oltp.Employees(EmployeeID),
    Title           NVARCHAR(80)    NOT NULL,
    HireDate        DATE            NOT NULL,
    Region          NVARCHAR(60)    NOT NULL
);

------------------------------------------------------------------
-- Customers & geography
------------------------------------------------------------------
CREATE TABLE oltp.Customers (
    CustomerID      INT IDENTITY(1,1) PRIMARY KEY,
    FirstName       NVARCHAR(60)    NOT NULL,
    LastName        NVARCHAR(60)    NOT NULL,
    Email           NVARCHAR(150)   NOT NULL UNIQUE,
    Phone           VARCHAR(20)     NULL,
    SignupDate      DATE            NOT NULL DEFAULT CAST(SYSDATETIME() AS DATE),
    CustomerSegment VARCHAR(20)     NOT NULL DEFAULT 'Standard'
                        CHECK (CustomerSegment IN ('Standard','Premium','VIP')),
    IsActive        BIT             NOT NULL DEFAULT 1
);

CREATE TABLE oltp.ShippingAddresses (
    AddressID       INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID      INT             NOT NULL REFERENCES oltp.Customers(CustomerID),
    AddressLine1    NVARCHAR(150)   NOT NULL,
    City            NVARCHAR(80)    NOT NULL,
    State           NVARCHAR(80)    NOT NULL,
    Country         NVARCHAR(80)    NOT NULL,
    PostalCode      VARCHAR(15)     NOT NULL,
    IsDefault       BIT             NOT NULL DEFAULT 0
);

------------------------------------------------------------------
-- Products & inventory
------------------------------------------------------------------
CREATE TABLE oltp.Products (
    ProductID       INT IDENTITY(1,1) PRIMARY KEY,
    ProductName     NVARCHAR(150)   NOT NULL,
    CategoryID      INT             NOT NULL REFERENCES oltp.Categories(CategoryID),
    SupplierID      INT             NOT NULL REFERENCES oltp.Suppliers(SupplierID),
    UnitPrice       DECIMAL(10,2)   NOT NULL CHECK (UnitPrice >= 0),
    ReorderLevel    INT             NOT NULL DEFAULT 20,
    Discontinued    BIT             NOT NULL DEFAULT 0
);

CREATE TABLE oltp.Inventory (
    ProductID       INT             PRIMARY KEY REFERENCES oltp.Products(ProductID),
    QuantityOnHand  INT             NOT NULL CHECK (QuantityOnHand >= 0),
    WarehouseLocation NVARCHAR(60)  NOT NULL DEFAULT 'MAIN',
    LastRestockDate DATE            NULL
);

------------------------------------------------------------------
-- Orders / transactions
------------------------------------------------------------------
CREATE TABLE oltp.Orders (
    OrderID         INT IDENTITY(1,1) PRIMARY KEY,
    CustomerID      INT             NOT NULL REFERENCES oltp.Customers(CustomerID),
    EmployeeID      INT             NULL REFERENCES oltp.Employees(EmployeeID),
    AddressID       INT             NOT NULL REFERENCES oltp.ShippingAddresses(AddressID),
    OrderDate       DATETIME2       NOT NULL DEFAULT SYSDATETIME(),
    OrderStatus     VARCHAR(20)     NOT NULL DEFAULT 'Pending'
                        CHECK (OrderStatus IN ('Pending','Confirmed','Shipped','Delivered','Cancelled')),
    TotalAmount     DECIMAL(12,2)   NOT NULL DEFAULT 0 CHECK (TotalAmount >= 0)
);

CREATE TABLE oltp.OrderDetails (
    OrderDetailID   INT IDENTITY(1,1) PRIMARY KEY,
    OrderID         INT             NOT NULL REFERENCES oltp.Orders(OrderID),
    ProductID       INT             NOT NULL REFERENCES oltp.Products(ProductID),
    Quantity        INT             NOT NULL CHECK (Quantity > 0),
    UnitPrice       DECIMAL(10,2)   NOT NULL CHECK (UnitPrice >= 0),
    Discount        DECIMAL(4,2)    NOT NULL DEFAULT 0 CHECK (Discount BETWEEN 0 AND 1),
    LineTotal       AS (Quantity * UnitPrice * (1 - Discount)) PERSISTED
);

CREATE TABLE oltp.Payments (
    PaymentID       INT IDENTITY(1,1) PRIMARY KEY,
    OrderID         INT             NOT NULL REFERENCES oltp.Orders(OrderID),
    PaymentDate     DATETIME2       NOT NULL DEFAULT SYSDATETIME(),
    Amount          DECIMAL(12,2)   NOT NULL CHECK (Amount >= 0),
    PaymentMethod   VARCHAR(20)     NOT NULL
                        CHECK (PaymentMethod IN ('CreditCard','DebitCard','UPI','NetBanking','COD')),
    PaymentStatus   VARCHAR(20)     NOT NULL DEFAULT 'Success'
                        CHECK (PaymentStatus IN ('Success','Failed','Refunded'))
);

CREATE TABLE oltp.Returns (
    ReturnID        INT IDENTITY(1,1) PRIMARY KEY,
    OrderDetailID   INT             NOT NULL REFERENCES oltp.OrderDetails(OrderDetailID),
    ReturnDate      DATETIME2       NOT NULL DEFAULT SYSDATETIME(),
    QuantityReturned INT            NOT NULL CHECK (QuantityReturned > 0),
    Reason          NVARCHAR(200)   NULL,
    RefundAmount    DECIMAL(12,2)   NOT NULL CHECK (RefundAmount >= 0)
);
GO

------------------------------------------------------------------
-- Audit / error logging (used by procedures in script 04-05)
------------------------------------------------------------------
CREATE TABLE audit.OrderAuditLog (
    AuditID         INT IDENTITY(1,1) PRIMARY KEY,
    OrderID         INT             NOT NULL,
    Action          VARCHAR(20)     NOT NULL,
    ActionDetail    NVARCHAR(400)   NULL,
    ActionAt        DATETIME2       NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE audit.ErrorLog (
    ErrorLogID      INT IDENTITY(1,1) PRIMARY KEY,
    ErrorProcedure  NVARCHAR(200)   NULL,
    ErrorNumber     INT             NULL,
    ErrorMessage    NVARCHAR(2000)  NULL,
    ErrorAt         DATETIME2       NOT NULL DEFAULT SYSDATETIME()
);
GO

PRINT 'OLTP schema created successfully.';
