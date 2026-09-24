/*
====================================================================
 03_insert_sample_data.sql

 Purpose : Seed lookup data, then generate volume programmatically
           so the project has enough rows for real indexing/window-
           function/performance work (not a 20-row toy dataset).
 Covers  : Set-based inserts, WHILE loops, built-in random/date
           functions, CROSS JOIN row generation.

 NOTE: This uses NEWID()-driven randomness, so exact row content
 differs every run - re-run steps 04-07 examples after loading.
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- 1. Lookup data
------------------------------------------------------------------
INSERT INTO oltp.Categories (CategoryName, Description) VALUES
('Electronics','Consumer electronics and accessories'),
('Home & Kitchen','Home goods and kitchen appliances'),
('Apparel','Clothing and footwear'),
('Sports & Outdoors','Fitness and outdoor equipment'),
('Books','Print and digital books'),
('Beauty & Personal Care','Cosmetics and grooming'),
('Toys & Games','Toys, games and puzzles'),
('Office Supplies','Stationery and office equipment');

INSERT INTO oltp.Suppliers (SupplierName, ContactEmail, Phone, Country) VALUES
('Northwind Traders','contact@northwind.com','555-0101','USA'),
('Global Gadgets Ltd','sales@globalgadgets.com','555-0102','India'),
('Prime Home Supplies','info@primehome.com','555-0103','India'),
('Everest Sportswear','hello@everestsport.com','555-0104','Nepal'),
('Bright Books Co','orders@brightbooks.com','555-0105','UK'),
('Lumina Beauty','support@luminabeauty.com','555-0106','India'),
('FunTime Toys','sales@funtimetoys.com','555-0107','China'),
('OfficePro Distributors','contact@officepro.com','555-0108','USA');

INSERT INTO oltp.Employees (FirstName, LastName, ManagerID, Title, HireDate, Region) VALUES
('Aditi','Sharma', NULL, 'Sales Director', '2019-01-15','North'),
('Rohan','Verma', 1, 'Sales Manager', '2020-03-01','North'),
('Kiran','Nair', 1, 'Sales Manager', '2020-06-10','South'),
('Neha','Gupta', 2, 'Sales Executive', '2021-02-20','North'),
('Arjun','Iyer', 3, 'Sales Executive', '2021-05-15','South'),
('Priya','Das', 3, 'Sales Executive', '2022-01-10','South');
GO

------------------------------------------------------------------
-- 2. Products (24 products across the 8 categories/suppliers)
------------------------------------------------------------------
DECLARE @i INT = 1;
WHILE @i <= 24
BEGIN
    INSERT INTO oltp.Products (ProductName, CategoryID, SupplierID, UnitPrice, ReorderLevel, Discontinued)
    VALUES (
        CONCAT('Product ', @i),
        ((@i - 1) % 8) + 1,
        ((@i - 1) % 8) + 1,
        CAST(50 + (RAND(CHECKSUM(NEWID())) * 950) AS DECIMAL(10,2)),
        10 + (@i % 5) * 5,
        CASE WHEN @i % 17 = 0 THEN 1 ELSE 0 END
    );
    SET @i += 1;
END
GO

INSERT INTO oltp.Inventory (ProductID, QuantityOnHand, WarehouseLocation, LastRestockDate)
SELECT
    ProductID,
    20 + ABS(CHECKSUM(NEWID())) % 500,
    CASE WHEN ProductID % 2 = 0 THEN 'MAIN' ELSE 'NORTH-DC' END,
    DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 60, CAST(SYSDATETIME() AS DATE))
FROM oltp.Products;
GO

------------------------------------------------------------------
-- 3. Customers (500) and one shipping address each
------------------------------------------------------------------
DECLARE @n INT = 1;
DECLARE @cities TABLE (City NVARCHAR(80), State NVARCHAR(80), Country NVARCHAR(80));
INSERT INTO @cities VALUES
('Delhi','Delhi','India'),('Mumbai','Maharashtra','India'),('Bengaluru','Karnataka','India'),
('Chennai','Tamil Nadu','India'),('Pune','Maharashtra','India'),('Hyderabad','Telangana','India'),
('Kolkata','West Bengal','India'),('Ahmedabad','Gujarat','India');

WHILE @n <= 500
BEGIN
    INSERT INTO oltp.Customers (FirstName, LastName, Email, Phone, SignupDate, CustomerSegment, IsActive)
    VALUES (
        CONCAT('First', @n),
        CONCAT('Last', @n),
        CONCAT('customer', @n, '@example.com'),
        CONCAT('9', RIGHT('000000000' + CAST(ABS(CHECKSUM(NEWID())) % 1000000000 AS VARCHAR(10)), 9)),
        DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 900, CAST(SYSDATETIME() AS DATE)),
        CASE WHEN @n % 20 = 0 THEN 'VIP' WHEN @n % 5 = 0 THEN 'Premium' ELSE 'Standard' END,
        CASE WHEN @n % 37 = 0 THEN 0 ELSE 1 END
    );
    SET @n += 1;
END
GO

INSERT INTO oltp.ShippingAddresses (CustomerID, AddressLine1, City, State, Country, PostalCode, IsDefault)
SELECT
    c.CustomerID,
    CONCAT(ABS(CHECKSUM(NEWID())) % 999, ' Main Street'),
    ct.City, ct.State, ct.Country,
    RIGHT('000000' + CAST(100000 + ABS(CHECKSUM(NEWID())) % 899999 AS VARCHAR(6)), 6),
    1
FROM oltp.Customers c
CROSS APPLY (
    SELECT TOP 1 * FROM (VALUES
        ('Delhi','Delhi','India'),('Mumbai','Maharashtra','India'),('Bengaluru','Karnataka','India'),
        ('Chennai','Tamil Nadu','India'),('Pune','Maharashtra','India'),('Hyderabad','Telangana','India'),
        ('Kolkata','West Bengal','India'),('Ahmedabad','Gujarat','India')
    ) v(City,State,Country)
    ORDER BY (ABS(CHECKSUM(NEWID(), c.CustomerID)))
) ct;
GO

------------------------------------------------------------------
-- 4. Orders + OrderDetails + Payments (~6000 orders, ~15000 lines)
--    Loaded in batches via a numbers table for speed and clarity.
------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Numbers') IS NOT NULL DROP TABLE #Numbers;
SELECT TOP (6000) IDENTITY(INT,1,1) AS n
INTO #Numbers
FROM sys.all_objects a CROSS JOIN sys.all_objects b;

DECLARE @maxCust INT = (SELECT MAX(CustomerID) FROM oltp.Customers);
DECLARE @maxEmp  INT = (SELECT MAX(EmployeeID) FROM oltp.Employees);

INSERT INTO oltp.Orders (CustomerID, EmployeeID, AddressID, OrderDate, OrderStatus, TotalAmount)
SELECT
    cust.CustomerID,
    1 + ABS(CHECKSUM(NEWID())) % @maxEmp,
    addr.AddressID,
    DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 730, SYSDATETIME()),
    CASE ABS(CHECKSUM(NEWID())) % 20
        WHEN 0 THEN 'Cancelled'
        WHEN 1 THEN 'Pending'
        ELSE 'Delivered'
    END,
    0   -- TotalAmount is recalculated below once OrderDetails exist
FROM #Numbers num
CROSS APPLY (SELECT TOP 1 CustomerID FROM oltp.Customers ORDER BY (ABS(CHECKSUM(NEWID(), num.n)))) cust
CROSS APPLY (SELECT TOP 1 AddressID FROM oltp.ShippingAddresses WHERE CustomerID = cust.CustomerID) addr;
GO

-- 1 to 4 order lines per order
INSERT INTO oltp.OrderDetails (OrderID, ProductID, Quantity, UnitPrice, Discount)
SELECT
    o.OrderID,
    p.ProductID,
    1 + ABS(CHECKSUM(NEWID())) % 5,
    p.UnitPrice,
    CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN 0.10 ELSE 0 END
FROM oltp.Orders o
CROSS APPLY (SELECT TOP (1 + ABS(CHECKSUM(NEWID())) % 4) ProductID, UnitPrice
             FROM oltp.Products ORDER BY NEWID()) p;
GO

UPDATE o
SET TotalAmount = od.OrderTotal
FROM oltp.Orders o
JOIN (
    SELECT OrderID, SUM(LineTotal) AS OrderTotal
    FROM oltp.OrderDetails
    GROUP BY OrderID
) od ON od.OrderID = o.OrderID;
GO

INSERT INTO oltp.Payments (OrderID, PaymentDate, Amount, PaymentMethod, PaymentStatus)
SELECT
    OrderID,
    DATEADD(MINUTE, 5, OrderDate),
    TotalAmount,
    CASE ABS(CHECKSUM(NEWID())) % 5
        WHEN 0 THEN 'CreditCard' WHEN 1 THEN 'DebitCard' WHEN 2 THEN 'UPI'
        WHEN 3 THEN 'NetBanking' ELSE 'COD' END,
    CASE WHEN ABS(CHECKSUM(NEWID())) % 25 = 0 THEN 'Failed' ELSE 'Success' END
FROM oltp.Orders
WHERE OrderStatus <> 'Cancelled';
GO

------------------------------------------------------------------
-- 5. A modest set of returns, tied to delivered order lines
------------------------------------------------------------------
INSERT INTO oltp.Returns (OrderDetailID, ReturnDate, QuantityReturned, Reason, RefundAmount)
SELECT TOP (300)
    od.OrderDetailID,
    DATEADD(DAY, 5 + ABS(CHECKSUM(NEWID())) % 20, o.OrderDate),
    1,
    'Customer changed mind',
    od.UnitPrice
FROM oltp.OrderDetails od
JOIN oltp.Orders o ON o.OrderID = od.OrderID
WHERE o.OrderStatus = 'Delivered'
ORDER BY NEWID();
GO

PRINT 'Sample data loaded: ' +
      CAST((SELECT COUNT(*) FROM oltp.Customers) AS VARCHAR) + ' customers, ' +
      CAST((SELECT COUNT(*) FROM oltp.Orders) AS VARCHAR) + ' orders, ' +
      CAST((SELECT COUNT(*) FROM oltp.OrderDetails) AS VARCHAR) + ' order lines.';
