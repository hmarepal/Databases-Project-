-- =====================================================================
-- 1. HEADER META
-- =====================================================================
-- Team name : Group 8
-- Members   : Cesar Lozano, Gabriel Castro, Mahamudur Daiyan, Hemal Marepalli, Patrick Sykes
-- Course    : CS 4354 Concepts of Database Systems, Fall 2026
-- Project   : Airport Booking Database
-- MySQL     : 8.0.x (8.0.16+ required for CHECK constraint enforcement)
-- Run       : mysql -u <user> -p < TeamName_Project.sql
--             (or open in MySQL Workbench and Execute All)
--
-- Requirements
--   R1  A flight's origin and destination airports must differ, and its
--       scheduled arrival must be after its scheduled departure.
--   R2  A passenger can hold many bookings; each booking has one or more
--       ordered flight segments.
--   R3  A seat on a given flight can be assigned to at most one passenger.
--   R4  The number of segments booked on a flight cannot exceed the
--       capacity of the aircraft assigned to it.
--   R5  Users can search flights by origin, destination, and date.
-- =====================================================================


-- =====================================================================
-- 2. SESSION SETUP
-- =====================================================================
SET sql_mode = 'STRICT_TRANS_TABLES,ONLY_FULL_GROUP_BY';
SET FOREIGN_KEY_CHECKS = 0;


-- =====================================================================
-- 3. (RE)CREATE SCHEMA
-- =====================================================================
DROP DATABASE IF EXISTS airport_booking;
CREATE DATABASE airport_booking;
USE airport_booking;

-- ---------------------------------------------------------------------
-- Airport
-- Purpose: Reference list of every airport a flight can depart from or
--          arrive at.
-- What it does: Stores each airport once, keyed by its 3-letter IATA code,
--          so city/country are not repeated on every flight (removes the
--          airport_code -> city dependency from the flat design). Flight
--          references it twice, as origin and as destination.
-- ---------------------------------------------------------------------
CREATE TABLE Airport (
    airport_code  CHAR(3)       NOT NULL,          -- IATA code (natural key)
    name          VARCHAR(100)  NOT NULL,
    city          VARCHAR(60)   NOT NULL,
    country       VARCHAR(60)   NOT NULL,
    PRIMARY KEY (airport_code)
);

-- ---------------------------------------------------------------------
-- Airline
-- Purpose: Reference list of carriers that operate flights and own aircraft.
-- What it does: Stores each airline once, keyed by its 2-letter IATA code.
--          Aircraft and Flight both reference it, so an airline name is
--          changed in one place only.
-- ---------------------------------------------------------------------
CREATE TABLE Airline (
    airline_code  CHAR(2)       NOT NULL,          -- IATA code (natural key)
    name          VARCHAR(80)   NOT NULL,
    PRIMARY KEY (airline_code),
    UNIQUE (name)
);

-- ---------------------------------------------------------------------
-- Aircraft
-- Purpose: Physical planes owned by an airline, with their seat capacity.
-- What it does: Supplies the capacity used by the R4 trigger. The
--          UNIQUE (aircraft_id, airline_code) pair lets Flight use a
--          composite FK so a flight can only be assigned an aircraft that
--          belongs to the same airline operating it.
-- ---------------------------------------------------------------------
CREATE TABLE Aircraft (
    aircraft_id   INT           NOT NULL AUTO_INCREMENT,
    airline_code  CHAR(2)       NOT NULL,
    model         VARCHAR(40)   NOT NULL,
    capacity      SMALLINT      NOT NULL,
    PRIMARY KEY (aircraft_id),
    UNIQUE (aircraft_id, airline_code),            -- target of Flight's composite FK
    FOREIGN KEY (airline_code) REFERENCES Airline (airline_code),
    CHECK (capacity > 0)
);

-- ---------------------------------------------------------------------
-- Flight
-- Purpose: One scheduled operation of a flight number on a specific date
--          and time (e.g., AA3301 on 2026-12-15 06:00).
-- What it does: Links airline, aircraft, origin airport, and destination
--          airport. Uses a surrogate key because flight numbers repeat
--          daily; UNIQUE (airline_code, flight_number, sched_dep) prevents
--          duplicate schedule entries. Enforces R1 through CHECK
--          constraints and records actual times and gate as they become
--          known (NULL until then). Searched by R5 via the composite index.
-- ---------------------------------------------------------------------
CREATE TABLE Flight (
    flight_id      INT          NOT NULL AUTO_INCREMENT,  -- surrogate: flight numbers repeat daily
    airline_code   CHAR(2)      NOT NULL,
    flight_number  SMALLINT     NOT NULL,
    aircraft_id    INT          NOT NULL,
    origin         CHAR(3)      NOT NULL,
    dest           CHAR(3)      NOT NULL,
    sched_dep      DATETIME     NOT NULL,
    sched_arr      DATETIME     NOT NULL,
    actual_dep     DATETIME     NULL,              -- NULL until the flight departs
    actual_arr     DATETIME     NULL,              -- NULL until the flight lands
    gate           VARCHAR(4)   NULL,              -- NULL until a gate is assigned
    PRIMARY KEY (flight_id),
    UNIQUE (airline_code, flight_number, sched_dep),
    FOREIGN KEY (airline_code) REFERENCES Airline (airline_code),
    -- composite FK: aircraft must belong to the operating airline
    FOREIGN KEY (aircraft_id, airline_code) REFERENCES Aircraft (aircraft_id, airline_code),
    FOREIGN KEY (origin) REFERENCES Airport (airport_code),
    FOREIGN KEY (dest)   REFERENCES Airport (airport_code),
    CONSTRAINT chk_route     CHECK (origin <> dest),                       -- R1
    CONSTRAINT chk_sched     CHECK (sched_arr > sched_dep),                -- R1
    CONSTRAINT chk_actual    CHECK (actual_dep IS NULL OR actual_arr IS NULL
                                    OR actual_arr > actual_dep),
    CONSTRAINT chk_flightno  CHECK (flight_number > 0)
);

-- ---------------------------------------------------------------------
-- Passenger
-- Purpose: People who travel and make bookings.
-- What it does: Stores identity and contact details once per person.
--          email is UNIQUE so each account is one person; passport_no is
--          UNIQUE but nullable because domestic-only travelers may not
--          have one on file.
-- ---------------------------------------------------------------------
CREATE TABLE Passenger (
    passenger_id  INT           NOT NULL AUTO_INCREMENT,
    first_name    VARCHAR(50)   NOT NULL,
    last_name     VARCHAR(50)   NOT NULL,
    email         VARCHAR(100)  NOT NULL,
    passport_no   VARCHAR(20)   NULL,              -- NULL for domestic-only travelers
    PRIMARY KEY (passenger_id),
    UNIQUE (email),
    UNIQUE (passport_no)
);

-- ---------------------------------------------------------------------
-- Booking
-- Purpose: A single reservation (itinerary) purchased by one passenger.
-- What it does: Holds the customer-facing confirmation code (booking_ref),
--          purchase time, and total price. One passenger can have many
--          bookings (1:N, R2). The individual flights in the trip are
--          stored in Segment, not here.
-- ---------------------------------------------------------------------
CREATE TABLE Booking (
    booking_id    INT           NOT NULL AUTO_INCREMENT,
    booking_ref   CHAR(6)       NOT NULL,          -- confirmation code shown to customer
    passenger_id  INT           NOT NULL,
    booked_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_price   DECIMAL(8,2)  NOT NULL,
    PRIMARY KEY (booking_id),
    UNIQUE (booking_ref),
    FOREIGN KEY (passenger_id) REFERENCES Passenger (passenger_id),
    CHECK (total_price >= 0)
);

-- ---------------------------------------------------------------------
-- Segment
-- Purpose: One leg of a booking (e.g., LBB -> DFW, then DFW -> LAX).
-- What it does: Resolves the M:N between Booking and Flight (a booking
--          has many flights; a flight carries many bookings). segment_no
--          orders the legs within a booking (R2). UNIQUE (flight_id, seat)
--          guarantees one passenger per seat on a flight (R3), while
--          allowing multiple NULL seats for passengers who have not picked
--          one yet. Every insert is checked by trg_segment_capacity (R4).
--          Deleting a booking cascades to its segments.
-- ---------------------------------------------------------------------
CREATE TABLE Segment (
    booking_id    INT           NOT NULL,
    segment_no    TINYINT       NOT NULL,          -- order of legs within a booking
    flight_id     INT           NOT NULL,
    seat          VARCHAR(4)    NULL,              -- NULL until passenger picks a seat
    fare_class    VARCHAR(10)   NOT NULL,
    PRIMARY KEY (booking_id, segment_no),
    UNIQUE (booking_id, flight_id),                -- same flight not twice in one booking
    UNIQUE (flight_id, seat),                      -- R3 (multiple NULL seats allowed)
    FOREIGN KEY (booking_id) REFERENCES Booking (booking_id) ON DELETE CASCADE,
    FOREIGN KEY (flight_id)  REFERENCES Flight (flight_id),
    CHECK (segment_no > 0),
    CHECK (fare_class IN ('ECONOMY', 'PREMIUM', 'BUSINESS', 'FIRST'))
);

-- R4: CHECK cannot reference another table, so capacity is enforced by trigger
DELIMITER //
CREATE TRIGGER trg_segment_capacity
BEFORE INSERT ON Segment
FOR EACH ROW
BEGIN
    DECLARE booked INT;
    DECLARE cap    INT;

    SELECT COUNT(*) INTO booked
    FROM Segment
    WHERE flight_id = NEW.flight_id;

    SELECT a.capacity INTO cap
    FROM Flight f
    JOIN Aircraft a ON a.aircraft_id = f.aircraft_id
    WHERE f.flight_id = NEW.flight_id;

    IF booked >= cap THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'R4 violation: flight is at aircraft capacity';
    END IF;
END//
DELIMITER ;


-- =====================================================================
-- 4. SEED DATA (minimal)
-- =====================================================================
INSERT INTO Airport (airport_code, name, city, country) VALUES
('LBB', 'Lubbock Preston Smith International',     'Lubbock',     'USA'),
('DFW', 'Dallas/Fort Worth International',          'Dallas',      'USA'),
('AUS', 'Austin-Bergstrom International',           'Austin',      'USA'),
('IAH', 'George Bush Intercontinental',             'Houston',     'USA'),
('DEN', 'Denver International',                     'Denver',      'USA'),
('LAX', 'Los Angeles International',                'Los Angeles', 'USA');

INSERT INTO Airline (airline_code, name) VALUES
('AA', 'American Airlines'),
('WN', 'Southwest Airlines'),
('UA', 'United Airlines');

-- Aircraft 1 has an artificially small capacity so R4 can be demonstrated
INSERT INTO Aircraft (aircraft_id, airline_code, model, capacity) VALUES
(1, 'AA', 'CRJ-700 (demo capacity)', 4),
(2, 'AA', 'Airbus A321',            190),
(3, 'WN', 'Boeing 737-800',         175),
(4, 'UA', 'Boeing 737 MAX 9',       179);

INSERT INTO Flight (flight_id, airline_code, flight_number, aircraft_id, origin, dest,
                    sched_dep, sched_arr, actual_dep, actual_arr, gate) VALUES
-- completed flight: actual times recorded
(1, 'UA',  501, 4, 'IAH', 'DEN', '2026-11-10 08:00', '2026-11-10 09:45',
                                 '2026-11-10 08:12', '2026-11-10 09:58', 'C14'),
-- upcoming flights: actual times NULL; some gates not yet assigned
(2, 'AA', 3301, 1, 'LBB', 'DFW', '2026-12-15 06:00', '2026-12-15 07:05', NULL, NULL, 'A2'),
(3, 'AA', 2210, 2, 'DFW', 'LAX', '2026-12-15 09:00', '2026-12-15 10:35', NULL, NULL, NULL),
(4, 'AA', 3305, 1, 'LBB', 'DFW', '2026-12-15 14:00', '2026-12-15 15:05', NULL, NULL, NULL),
(5, 'WN', 1150, 3, 'LBB', 'AUS', '2026-12-18 11:30', '2026-12-18 12:40', NULL, NULL, NULL),
(6, 'AA', 3301, 1, 'LBB', 'DFW', '2026-12-16 06:00', '2026-12-16 07:05', NULL, NULL, NULL);

INSERT INTO Passenger (passenger_id, first_name, last_name, email, passport_no) VALUES
(1, 'Maria',  'Lopez',    'mlopez@example.com',   'X12345678'),
(2, 'James',  'Carter',   'jcarter@example.com',  NULL),
(3, 'Aisha',  'Khan',     'akhan@example.com',    'P98765432'),
(4, 'Daniel', 'Nguyen',   'dnguyen@example.com',  NULL),
(5, 'Emily',  'Brooks',   'ebrooks@example.com',  NULL),
(6, 'Omar',   'Haddad',   'ohaddad@example.com',  'K55511122');

INSERT INTO Booking (booking_id, booking_ref, passenger_id, booked_at, total_price) VALUES
(1, 'QX7P2A', 1, '2026-10-01 10:15', 412.60),   -- multi-segment LBB -> DFW -> LAX
(2, 'MB4K9L', 2, '2026-10-03 18:40', 129.00),
(3, 'TZ8R1C', 3, '2026-10-05 07:22', 389.90),   -- multi-segment LBB -> DFW -> LAX
(4, 'HN2W6D', 4, '2026-10-09 12:05', 139.00),
(5, 'PL5V3E', 5, '2026-10-20 21:30',  98.50),   -- seat not yet selected
(6, 'RC1J8F', 6, '2026-09-28 09:00', 210.00);   -- completed trip

INSERT INTO Segment (booking_id, segment_no, flight_id, seat, fare_class) VALUES
(1, 1, 2, '1A',  'ECONOMY'),
(1, 2, 3, '14C', 'ECONOMY'),
(2, 1, 2, '1B',  'ECONOMY'),
(3, 1, 2, '2A',  'PREMIUM'),
(3, 2, 3, '3D',  'BUSINESS'),
(4, 1, 2, '2B',  'ECONOMY'),    -- flight 2 is now full (4 of 4)
(5, 1, 5, NULL,  'ECONOMY'),
(6, 1, 1, '22F', 'ECONOMY');


-- =====================================================================
-- 5. POST-CREATE: INDEXES
-- =====================================================================
-- Serves R5: WHERE origin = ? AND dest = ? AND sched_dep BETWEEN ? AND ?
CREATE INDEX idx_flight_route_date ON Flight (origin, dest, sched_dep);


-- =====================================================================
-- 6. VERIFICATION BLOCK
-- =====================================================================

-- Evidence Query 1 (R5): flights from Lubbock to Dallas/Fort Worth on 2026-12-15
SELECT f.airline_code, f.flight_number, f.origin, f.dest,
       f.sched_dep, f.sched_arr, f.gate
FROM Flight f
WHERE f.origin = 'LBB'
  AND f.dest   = 'DFW'
  AND f.sched_dep >= '2026-12-15 00:00:00'
  AND f.sched_dep <  '2026-12-16 00:00:00'
ORDER BY f.sched_dep;

-- Index check for Query 1 (expect key = idx_flight_route_date, type = range)
EXPLAIN
SELECT f.flight_id
FROM Flight f
WHERE f.origin = 'LBB'
  AND f.dest   = 'DFW'
  AND f.sched_dep >= '2026-12-15 00:00:00'
  AND f.sched_dep <  '2026-12-16 00:00:00';

-- Evidence Query 2 (R2): full ordered itinerary for booking QX7P2A
SELECT b.booking_ref,
       CONCAT(p.first_name, ' ', p.last_name) AS passenger,
       s.segment_no,
       CONCAT(f.airline_code, f.flight_number) AS flight,
       o.city AS from_city,
       d.city AS to_city,
       f.sched_dep, f.sched_arr,
       COALESCE(s.seat, 'Not assigned') AS seat,
       s.fare_class
FROM Booking b
JOIN Passenger p ON p.passenger_id = b.passenger_id
JOIN Segment   s ON s.booking_id   = b.booking_id
JOIN Flight    f ON f.flight_id    = s.flight_id
JOIN Airport   o ON o.airport_code = f.origin
JOIN Airport   d ON d.airport_code = f.dest
WHERE b.booking_ref = 'QX7P2A'
ORDER BY s.segment_no;

-- Evidence Query 3 (R4): load factor per flight (booked seats / capacity)
SELECT f.flight_id,
       CONCAT(f.airline_code, f.flight_number) AS flight,
       f.sched_dep,
       a.capacity,
       COUNT(s.booking_id) AS booked,
       ROUND(100 * COUNT(s.booking_id) / a.capacity, 1) AS load_pct
FROM Flight f
JOIN Aircraft a     ON a.aircraft_id = f.aircraft_id
LEFT JOIN Segment s ON s.flight_id   = f.flight_id
GROUP BY f.flight_id, f.airline_code, f.flight_number, f.sched_dep, a.capacity
ORDER BY load_pct DESC;

-- NULL-aware query: upcoming flights that have not departed yet
SELECT flight_id, airline_code, flight_number, sched_dep
FROM Flight
WHERE actual_dep IS NULL
ORDER BY sched_dep;

-- ---------------------------------------------------------------------
-- Constraint demos (commented out so the script runs to completion).
-- Uncomment one at a time and run to capture the error screenshot.
-- ---------------------------------------------------------------------

-- Demo A (R3): duplicate seat on flight 2 -> ERROR 1062 Duplicate entry
-- INSERT INTO Segment (booking_id, segment_no, flight_id, seat, fare_class)
-- VALUES (5, 2, 3, '14C', 'ECONOMY');

-- Demo B (R4): flight 2 is at capacity -> ERROR 1644 'R4 violation...'
-- INSERT INTO Segment (booking_id, segment_no, flight_id, seat, fare_class)
-- VALUES (5, 2, 2, '3A', 'ECONOMY');

-- Demo C (R1): origin equals destination -> ERROR 3819 Check constraint 'chk_route'
-- INSERT INTO Flight (airline_code, flight_number, aircraft_id, origin, dest, sched_dep, sched_arr)
-- VALUES ('AA', 9999, 2, 'LBB', 'LBB', '2026-12-20 08:00', '2026-12-20 09:00');

-- Demo D: aircraft from another airline -> ERROR 1452 FK constraint fails
--         (run after SET FOREIGN_KEY_CHECKS = 1)
-- INSERT INTO Flight (airline_code, flight_number, aircraft_id, origin, dest, sched_dep, sched_arr)
-- VALUES ('WN', 777, 2, 'LBB', 'AUS', '2026-12-20 08:00', '2026-12-20 09:10');


-- =====================================================================
-- 7. SESSION RESTORE
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 1;
