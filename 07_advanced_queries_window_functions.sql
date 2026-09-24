/*
====================================================================
 07_advanced_queries_window_functions.sql

 Purpose : Analytical query showcase against the star schema -
           the queries you'd screenshot for a LinkedIn post/README.
 Covers  : Window functions, recursive CTEs, PIVOT, gaps-and-islands,
           set operators.
====================================================================
*/

USE RetailFlowDB;
GO

------------------------------------------------------------------
-- 7.1 Running total of monthly sales + month-over-month growth
------------------------------------------------------------------
SELECT
    d.Year, d.MonthNumber, d.MonthName,
    SUM(f.LineTotal) AS MonthlySales,
    SUM(SUM(f.LineTotal)) OVER (ORDER BY d.Year, d.MonthNumber
                                 ROWS UNBOUNDED PRECEDING) AS RunningTotal,
    LAG(SUM(f.LineTotal)) OVER (ORDER BY d.Year, d.MonthNumber) AS PrevMonthSales,
    SUM(f.LineTotal) - LAG(SUM(f.LineTotal)) OVER (ORDER BY d.Year, d.MonthNumber) AS MoMChange
FROM star.FactSales f
JOIN star.DimDate d ON d.DateKey = f.DateKey
GROUP BY d.Year, d.MonthNumber, d.MonthName
ORDER BY d.Year, d.MonthNumber;
GO


------------------------------------------------------------------
-- 7.2 Top 5 customers by revenue, per region, using RANK
------------------------------------------------------------------
WITH CustomerRevenue AS (
    SELECT
        e.Region,
        c.FullName,
        SUM(f.LineTotal) AS Revenue,
        RANK() OVER (PARTITION BY e.Region ORDER BY SUM(f.LineTotal) DESC) AS RegionRank
    FROM star.FactSales f
    JOIN star.DimCustomer c ON c.CustomerKey = f.CustomerKey
    JOIN star.DimEmployee e ON e.EmployeeKey = f.EmployeeKey
    GROUP BY e.Region, c.FullName
)
SELECT * FROM CustomerRevenue WHERE RegionRank <= 5 ORDER BY Region, RegionRank;
GO


------------------------------------------------------------------
-- 7.3 Recursive CTE: employee management hierarchy with level
------------------------------------------------------------------
WITH EmployeeHierarchy AS (
    SELECT EmployeeID, FirstName, LastName, ManagerID, Title, 0 AS HierarchyLevel
    FROM oltp.Employees
    WHERE ManagerID IS NULL

    UNION ALL

    SELECT e.EmployeeID, e.FirstName, e.LastName, e.ManagerID, e.Title, eh.HierarchyLevel + 1
    FROM oltp.Employees e
    JOIN EmployeeHierarchy eh ON e.ManagerID = eh.EmployeeID
)
SELECT
    REPLICATE('    ', HierarchyLevel) + FirstName + ' ' + LastName AS OrgChart,
    Title, HierarchyLevel
FROM EmployeeHierarchy
ORDER BY HierarchyLevel, LastName;
GO


------------------------------------------------------------------
-- 7.4 PIVOT: category revenue by quarter as a matrix
------------------------------------------------------------------
SELECT CategoryName, [1] AS Q1, [2] AS Q2, [3] AS Q3, [4] AS Q4
FROM (
    SELECT p.CategoryName, d.Quarter, f.LineTotal
    FROM star.FactSales f
    JOIN star.DimProduct p ON p.ProductKey = f.ProductKey
    JOIN star.DimDate d ON d.DateKey = f.DateKey
    WHERE d.Year = YEAR(GETDATE())
) src
PIVOT (
    SUM(LineTotal) FOR Quarter IN ([1],[2],[3],[4])
) pvt
ORDER BY CategoryName;
GO


------------------------------------------------------------------
-- 7.5 Gaps-and-islands: find customers with 60+ consecutive days
--     without an order (churn-risk candidates)
------------------------------------------------------------------
WITH OrderDates AS (
    SELECT DISTINCT c.CustomerID, CAST(o.OrderDate AS DATE) AS OrderDay
    FROM oltp.Orders o
    JOIN oltp.Customers c ON c.CustomerID = o.CustomerID
),
NumberedDates AS (
    SELECT CustomerID, OrderDay,
           ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY OrderDay) AS rn
    FROM OrderDates
),
Islands AS (
    SELECT CustomerID, OrderDay,
           DATEADD(DAY, -rn, OrderDay) AS IslandGroup   -- constant within a consecutive run
    FROM NumberedDates
),
Gaps AS (
    SELECT CustomerID, MIN(OrderDay) AS IslandStart, MAX(OrderDay) AS IslandEnd
    FROM Islands
    GROUP BY CustomerID, IslandGroup
)
SELECT
    g1.CustomerID,
    g1.IslandEnd AS LastOrderInIsland,
    g2.IslandStart AS NextOrderAfterGap,
    DATEDIFF(DAY, g1.IslandEnd, g2.IslandStart) AS GapDays
FROM Gaps g1
JOIN Gaps g2 ON g2.CustomerID = g1.CustomerID AND g2.IslandStart > g1.IslandEnd
WHERE DATEDIFF(DAY, g1.IslandEnd, g2.IslandStart) >= 60
ORDER BY GapDays DESC;
GO


------------------------------------------------------------------
-- 7.6 Set operators: customers who bought Electronics but never
--     Apparel (EXCEPT), vs. customers who bought both (INTERSECT)
------------------------------------------------------------------
WITH ElectronicsBuyers AS (
    SELECT DISTINCT f.CustomerKey
    FROM star.FactSales f JOIN star.DimProduct p ON p.ProductKey = f.ProductKey
    WHERE p.CategoryName = 'Electronics'
),
ApparelBuyers AS (
    SELECT DISTINCT f.CustomerKey
    FROM star.FactSales f JOIN star.DimProduct p ON p.ProductKey = f.ProductKey
    WHERE p.CategoryName = 'Apparel'
)
SELECT CustomerKey, 'Electronics only' AS Segment FROM ElectronicsBuyers EXCEPT SELECT CustomerKey, 'Electronics only' FROM ApparelBuyers
UNION ALL
SELECT CustomerKey, 'Bought both' FROM ElectronicsBuyers INTERSECT SELECT CustomerKey, 'Bought both' FROM ApparelBuyers;
GO
