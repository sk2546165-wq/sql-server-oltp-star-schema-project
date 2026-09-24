/*
====================================================================
 04_transactions_and_error_handling.sql

 Purpose : The centerpiece of the project - demonstrates real,
           defensible use of MS SQL transactions.
 Covers  : BEGIN TRAN/COMMIT/ROLLBACK, TRY...CATCH, XACT_ABORT,
           XACT_STATE(), SAVEPOINTs for partial rollback,
           isolation levels, and a deadlock reproduction script.
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- 4.1  usp_PlaceOrder
--      Classic "all-or-nothing" transaction: validate stock,
--      insert order + lines, decrement inventory, insert payment.
--      If ANY step fails, the whole order is rolled back.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE oltp.usp_PlaceOrder
    @CustomerID     INT,
    @EmployeeID     INT,
    @AddressID      INT,
    @ProductID      INT,
    @Quantity       INT,
    @PaymentMethod  VARCHAR(20),
    @NewOrderID     INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- any runtime error automatically rolls back the whole tran

    DECLARE @UnitPrice DECIMAL(10,2), @Available INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Lock the inventory row for the duration of the check+update (prevents oversell)
        SELECT @Available = QuantityOnHand, @UnitPrice = p.UnitPrice
        FROM oltp.Inventory i WITH (UPDLOCK, ROWLOCK)
        JOIN oltp.Products p ON p.ProductID = i.ProductID
        WHERE i.ProductID = @ProductID;

        IF @Available IS NULL
            THROW 51000, 'Product does not exist.', 1;

        IF @Available < @Quantity
            THROW 51001, 'Insufficient stock to fulfil this order.', 1;

        INSERT INTO oltp.Orders (CustomerID, EmployeeID, AddressID, OrderStatus, TotalAmount)
        VALUES (@CustomerID, @EmployeeID, @AddressID, 'Confirmed', @UnitPrice * @Quantity);

        SET @NewOrderID = SCOPE_IDENTITY();

        INSERT INTO oltp.OrderDetails (OrderID, ProductID, Quantity, UnitPrice, Discount)
        VALUES (@NewOrderID, @ProductID, @Quantity, @UnitPrice, 0);

        UPDATE oltp.Inventory
        SET QuantityOnHand = QuantityOnHand - @Quantity
        WHERE ProductID = @ProductID;

        INSERT INTO oltp.Payments (OrderID, Amount, PaymentMethod, PaymentStatus)
        VALUES (@NewOrderID, @UnitPrice * @Quantity, @PaymentMethod, 'Success');

        INSERT INTO audit.OrderAuditLog (OrderID, Action, ActionDetail)
        VALUES (@NewOrderID, 'PLACED', CONCAT('Qty=', @Quantity, ', Product=', @ProductID));

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO audit.ErrorLog (ErrorProcedure, ErrorNumber, ErrorMessage)
        VALUES (ERROR_PROCEDURE(), ERROR_NUMBER(), ERROR_MESSAGE());

        THROW;   -- re-raise to the caller after logging
    END CATCH
END
GO

-- Example calls:
-- DECLARE @oid INT; EXEC oltp.usp_PlaceOrder 1, 2, 1, 3, 2, 'UPI', @oid OUTPUT; SELECT @oid;
-- DECLARE @oid INT; EXEC oltp.usp_PlaceOrder 1, 2, 1, 3, 999999, 'UPI', @oid OUTPUT;  -- triggers insufficient-stock rollback


------------------------------------------------------------------
-- 4.2  usp_ProcessReturn
--      Demonstrates SAVEPOINTs: if the refund insert fails,
--      only the refund part rolls back - the return record itself
--      (already validated) is kept, matching how retailers often
--      want a "return logged, refund pending" state.
------------------------------------------------------------------
CREATE OR ALTER PROCEDURE oltp.usp_ProcessReturn
    @OrderDetailID      INT,
    @QuantityReturned   INT,
    @Reason             NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UnitPrice DECIMAL(10,2), @RefundAmount DECIMAL(12,2);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @UnitPrice = UnitPrice FROM oltp.OrderDetails WHERE OrderDetailID = @OrderDetailID;
        IF @UnitPrice IS NULL
            THROW 51002, 'Order line not found.', 1;

        SET @RefundAmount = @UnitPrice * @QuantityReturned;

        INSERT INTO oltp.Returns (OrderDetailID, QuantityReturned, Reason, RefundAmount)
        VALUES (@OrderDetailID, @QuantityReturned, @Reason, @RefundAmount);

        SAVE TRANSACTION BeforeRefund;   -- checkpoint after the return itself is safely recorded

        BEGIN TRY
            -- Simulated refund step against the Payments table
            UPDATE p
            SET p.PaymentStatus = 'Refunded'
            FROM oltp.Payments p
            JOIN oltp.OrderDetails od ON od.OrderID = p.OrderID
            WHERE od.OrderDetailID = @OrderDetailID;

            IF @@ROWCOUNT = 0
                THROW 51003, 'No matching payment found to refund.', 1;
        END TRY
        BEGIN CATCH
            -- Roll back only to the savepoint: keep the Returns row, drop the failed refund step
            ROLLBACK TRANSACTION BeforeRefund;
            INSERT INTO audit.ErrorLog (ErrorProcedure, ErrorNumber, ErrorMessage)
            VALUES ('usp_ProcessReturn (refund step)', ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        INSERT INTO audit.ErrorLog (ErrorProcedure, ErrorNumber, ErrorMessage)
        VALUES (ERROR_PROCEDURE(), ERROR_NUMBER(), ERROR_MESSAGE());
        THROW;
    END CATCH
END
GO


------------------------------------------------------------------
-- 4.3  Isolation level demo
--      Run these two blocks in TWO separate SSMS query windows to
--      see the difference. Session A holds an open transaction;
--      Session B reads under different isolation levels.
------------------------------------------------------------------

-- ===== SESSION A (run first, leave uncommitted) =====
-- BEGIN TRANSACTION;
-- UPDATE oltp.Inventory SET QuantityOnHand = QuantityOnHand - 1000 WHERE ProductID = 1;
-- -- do NOT commit yet - leave this transaction open

-- ===== SESSION B, attempt 1: dirty read =====
-- SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
-- SELECT QuantityOnHand FROM oltp.Inventory WHERE ProductID = 1;
-- -- returns Session A's uncommitted value - a "dirty read"

-- ===== SESSION B, attempt 2: blocked / consistent read =====
-- SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
-- SELECT QuantityOnHand FROM oltp.Inventory WHERE ProductID = 1;
-- -- blocks until Session A commits or rolls back, then returns the committed value

-- ===== SESSION A: finish the demo =====
-- ROLLBACK TRANSACTION;   -- Session B's blocked query then returns the original value


------------------------------------------------------------------
-- 4.4  Deadlock reproduction
--      Classic deadlock: two sessions update the same two rows in
--      opposite order. Run Session A up to the comment, then run
--      Session B fully, then resume Session A - SQL Server will
--      kill one session as the deadlock victim (Error 1205).
------------------------------------------------------------------

-- ===== SESSION A =====
-- BEGIN TRANSACTION;
-- UPDATE oltp.Inventory SET QuantityOnHand = QuantityOnHand - 1 WHERE ProductID = 1;
-- WAITFOR DELAY '00:00:05';
-- UPDATE oltp.Inventory SET QuantityOnHand = QuantityOnHand - 1 WHERE ProductID = 2;
-- COMMIT TRANSACTION;

-- ===== SESSION B (run within the 5-second window) =====
-- BEGIN TRANSACTION;
-- UPDATE oltp.Inventory SET QuantityOnHand = QuantityOnHand - 1 WHERE ProductID = 2;
-- UPDATE oltp.Inventory SET QuantityOnHand = QuantityOnHand - 1 WHERE ProductID = 1;
-- COMMIT TRANSACTION;

-- Fix demonstrated in usp_PlaceOrder above: always touch resources in a
-- consistent order (e.g. always lowest ProductID first) to avoid this class of deadlock.

PRINT 'Transaction procedures created: oltp.usp_PlaceOrder, oltp.usp_ProcessReturn';
