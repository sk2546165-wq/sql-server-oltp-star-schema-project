/*
====================================================================
 05_stored_procedures_triggers.sql

 Purpose : Programmability layer beyond the core transaction procs.
 Covers  : Scalar & table-valued functions, AFTER triggers,
           INSTEAD OF triggers, RAISERROR vs THROW, dynamic SQL basics,
           roles/permissions (DCL).
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- 5.1 Scalar function: customer lifetime value
------------------------------------------------------------------
CREATE OR ALTER FUNCTION oltp.ufn_CustomerLifetimeValue (@CustomerID INT)
RETURNS DECIMAL(14,2)
AS
BEGIN
    DECLARE @LTV DECIMAL(14,2);
    SELECT @LTV = SUM(TotalAmount)
    FROM oltp.Orders
    WHERE CustomerID = @CustomerID AND OrderStatus <> 'Cancelled';
    RETURN ISNULL(@LTV, 0);
END
GO
-- SELECT oltp.ufn_CustomerLifetimeValue(1);


------------------------------------------------------------------
-- 5.2 Inline table-valued function: order history for a customer
------------------------------------------------------------------
CREATE OR ALTER FUNCTION oltp.ufn_CustomerOrderHistory (@CustomerID INT)
RETURNS TABLE
AS
RETURN
(
    SELECT o.OrderID, o.OrderDate, o.OrderStatus, o.TotalAmount,
           COUNT(od.OrderDetailID) AS LineCount
    FROM oltp.Orders o
    JOIN oltp.OrderDetails od ON od.OrderID = o.OrderID
    WHERE o.CustomerID = @CustomerID
    GROUP BY o.OrderID, o.OrderDate, o.OrderStatus, o.TotalAmount
);
GO
-- SELECT * FROM oltp.ufn_CustomerOrderHistory(1);


------------------------------------------------------------------
-- 5.3 usp_ReplenishInventory: restock below-reorder-level products
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE oltp.usp_ReplenishInventory
    @TopUpQuantity INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE i
        SET QuantityOnHand = QuantityOnHand + @TopUpQuantity,
            LastRestockDate = CAST(SYSDATETIME() AS DATE)
        FROM oltp.Inventory i
        JOIN oltp.Products p ON p.ProductID = i.ProductID
        WHERE i.QuantityOnHand < p.ReorderLevel
          AND p.Discontinued = 0;

        DECLARE @RowsUpdated INT = @@ROWCOUNT;

        IF @RowsUpdated = 0
            RAISERROR('No products currently below reorder level.', 10, 1) WITH NOWAIT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        INSERT INTO audit.ErrorLog (ErrorProcedure, ErrorNumber, ErrorMessage)
        VALUES (ERROR_PROCEDURE(), ERROR_NUMBER(), ERROR_MESSAGE());
        THROW;
    END CATCH
END
GO


------------------------------------------------------------------
-- 5.4 AFTER trigger: audit every new order line automatically
------------------------------------------------------------------
CREATE OR ALTER TRIGGER oltp.trg_OrderDetails_AfterInsert
ON oltp.OrderDetails
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO audit.OrderAuditLog (OrderID, Action, ActionDetail)
    SELECT i.OrderID, 'LINE_ADDED',
           CONCAT('ProductID=', i.ProductID, ', Qty=', i.Quantity, ', LineTotal=', i.LineTotal)
    FROM inserted i;
END
GO


------------------------------------------------------------------
-- 5.5 INSTEAD OF trigger: enforce "no negative stock" even on a
--     direct UPDATE against oltp.Inventory (belt-and-braces beyond
--     the CHECK constraint - shows you understand trigger timing)
------------------------------------------------------------------
CREATE OR ALTER TRIGGER oltp.trg_Inventory_InsteadOfUpdate
ON oltp.Inventory
INSTEAD OF UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM inserted WHERE QuantityOnHand < 0)
    BEGIN
        RAISERROR('Update rejected: inventory cannot go negative.', 16, 1);
        RETURN;
    END

    UPDATE i
    SET QuantityOnHand   = ins.QuantityOnHand,
        WarehouseLocation = ins.WarehouseLocation,
        LastRestockDate   = ins.LastRestockDate
    FROM oltp.Inventory i
    JOIN inserted ins ON ins.ProductID = i.ProductID;
END
GO


------------------------------------------------------------------
-- 5.6 Basic dynamic SQL: parameterised report by any status column
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE oltp.usp_OrdersByStatus
    @Status VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT OrderID, CustomerID, OrderDate, TotalAmount
        FROM oltp.Orders
        WHERE OrderStatus = @StatusParam
        ORDER BY OrderDate DESC;';

    EXEC sp_executesql @sql, N'@StatusParam VARCHAR(20)', @StatusParam = @Status;
END
GO
-- EXEC oltp.usp_OrdersByStatus 'Delivered';


------------------------------------------------------------------
-- 5.7 Security (DCL): a read-only reporting role
------------------------------------------------------------------
-- CREATE ROLE db_reporting;
-- GRANT SELECT ON SCHEMA::star TO db_reporting;
-- GRANT SELECT ON SCHEMA::oltp TO db_reporting;
-- DENY INSERT, UPDATE, DELETE ON SCHEMA::oltp TO db_reporting;
-- CREATE USER powerbi_reader WITHOUT LOGIN;
-- ALTER ROLE db_reporting ADD MEMBER powerbi_reader;
-- EXECUTE AS USER = 'powerbi_reader';
--     SELECT TOP 5 * FROM star.FactSales;   -- works
--     -- INSERT INTO oltp.Orders ... would fail with a permission error
-- REVERT;

PRINT 'Functions, triggers and reporting procedures created.';
