-- MySQL dump 10.13  Distrib 8.0.46, for Win64 (x86_64)
--
-- Host: localhost    Database: college_complaints
-- ------------------------------------------------------
-- Server version	8.0.46

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!50503 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Table structure for table `academic_departments`
--

DROP TABLE IF EXISTS `academic_departments`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `academic_departments` (
  `academic_department_id` int NOT NULL AUTO_INCREMENT,
  `department_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  PRIMARY KEY (`academic_department_id`),
  UNIQUE KEY `department_name` (`department_name`)
) ENGINE=InnoDB AUTO_INCREMENT=11 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `complaint_details`
--

DROP TABLE IF EXISTS `complaint_details`;
/*!50001 DROP VIEW IF EXISTS `complaint_details`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `complaint_details` AS SELECT 
 1 AS `complaint_id`,
 1 AS `title`,
 1 AS `student_name`,
 1 AS `student_email`,
 1 AS `academic_department`,
 1 AS `responsible_department`,
 1 AS `category`,
 1 AS `priority`,
 1 AS `status`,
 1 AS `created_at`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `complaint_history`
--

DROP TABLE IF EXISTS `complaint_history`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `complaint_history` (
  `history_id` int NOT NULL AUTO_INCREMENT,
  `complaint_id` int NOT NULL,
  `old_status` varchar(30) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `new_status` varchar(30) COLLATE utf8mb4_unicode_ci NOT NULL,
  `changed_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `remarks` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`history_id`),
  KEY `complaint_id` (`complaint_id`),
  CONSTRAINT `complaint_history_ibfk_1` FOREIGN KEY (`complaint_id`) REFERENCES `complaints` (`complaint_id`) ON DELETE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=155 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `complaints`
--

DROP TABLE IF EXISTS `complaints`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `complaints` (
  `complaint_id` int NOT NULL AUTO_INCREMENT,
  `student_id` int NOT NULL,
  `department_id` int NOT NULL,
  `assigned_staff_id` int DEFAULT NULL,
  `title` varchar(180) COLLATE utf8mb4_unicode_ci NOT NULL,
  `description` text COLLATE utf8mb4_unicode_ci NOT NULL,
  `category` varchar(50) COLLATE utf8mb4_unicode_ci NOT NULL,
  `priority` enum('Low','Medium','High') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'Medium',
  `status` enum('Submitted','In Progress','Resolved','Rejected') COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'Submitted',
  `created_at` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
  `resolved_at` datetime DEFAULT NULL,
  PRIMARY KEY (`complaint_id`),
  KEY `student_id` (`student_id`),
  KEY `department_id` (`department_id`),
  KEY `assigned_staff_id` (`assigned_staff_id`),
  KEY `idx_complaints_created_at` (`created_at`),
  KEY `idx_complaints_status` (`status`),
  CONSTRAINT `complaints_ibfk_1` FOREIGN KEY (`student_id`) REFERENCES `students` (`student_id`),
  CONSTRAINT `complaints_ibfk_2` FOREIGN KEY (`department_id`) REFERENCES `departments` (`department_id`),
  CONSTRAINT `complaints_ibfk_3` FOREIGN KEY (`assigned_staff_id`) REFERENCES `staff` (`staff_id`)
) ENGINE=InnoDB AUTO_INCREMENT=202 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = cp850 */ ;
/*!50003 SET character_set_results = cp850 */ ;
/*!50003 SET collation_connection  = cp850_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `trg_complaint_status_history` AFTER UPDATE ON `complaints` FOR EACH ROW BEGIN
 IF OLD.status <> NEW.status THEN
 INSERT INTO complaint_history(complaint_id,old_status,new_status,remarks) VALUES(NEW.complaint_id,OLD.status,NEW.status,'Status updated from dashboard');
 END IF;
END */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Temporary view structure for view `department_complaint_summary`
--

DROP TABLE IF EXISTS `department_complaint_summary`;
/*!50001 DROP VIEW IF EXISTS `department_complaint_summary`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `department_complaint_summary` AS SELECT 
 1 AS `department_name`,
 1 AS `total_complaints`,
 1 AS `resolved_complaints`,
 1 AS `pending_complaints`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `departments`
--

DROP TABLE IF EXISTS `departments`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `departments` (
  `department_id` int NOT NULL AUTO_INCREMENT,
  `department_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `description` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`department_id`),
  UNIQUE KEY `department_name` (`department_name`)
) ENGINE=InnoDB AUTO_INCREMENT=6 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Temporary view structure for view `open_complaints`
--

DROP TABLE IF EXISTS `open_complaints`;
/*!50001 DROP VIEW IF EXISTS `open_complaints`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `open_complaints` AS SELECT 
 1 AS `complaint_id`,
 1 AS `title`,
 1 AS `student_name`,
 1 AS `student_email`,
 1 AS `academic_department`,
 1 AS `responsible_department`,
 1 AS `category`,
 1 AS `priority`,
 1 AS `status`,
 1 AS `created_at`*/;
SET character_set_client = @saved_cs_client;

--
-- Temporary view structure for view `pending_complaints`
--

DROP TABLE IF EXISTS `pending_complaints`;
/*!50001 DROP VIEW IF EXISTS `pending_complaints`*/;
SET @saved_cs_client     = @@character_set_client;
/*!50503 SET character_set_client = utf8mb4 */;
/*!50001 CREATE VIEW `pending_complaints` AS SELECT 
 1 AS `complaint_id`,
 1 AS `title`,
 1 AS `category`,
 1 AS `priority`,
 1 AS `status`,
 1 AS `created_at`,
 1 AS `student_name`,
 1 AS `department_name`*/;
SET character_set_client = @saved_cs_client;

--
-- Table structure for table `staff`
--

DROP TABLE IF EXISTS `staff`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `staff` (
  `staff_id` int NOT NULL AUTO_INCREMENT,
  `department_id` int NOT NULL,
  `full_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `email` varchar(120) COLLATE utf8mb4_unicode_ci NOT NULL,
  PRIMARY KEY (`staff_id`),
  UNIQUE KEY `email` (`email`),
  KEY `department_id` (`department_id`),
  CONSTRAINT `staff_ibfk_1` FOREIGN KEY (`department_id`) REFERENCES `departments` (`department_id`)
) ENGINE=InnoDB AUTO_INCREMENT=16 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Table structure for table `students`
--

DROP TABLE IF EXISTS `students`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!50503 SET character_set_client = utf8mb4 */;
CREATE TABLE `students` (
  `student_id` int NOT NULL AUTO_INCREMENT,
  `full_name` varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
  `email` varchar(120) COLLATE utf8mb4_unicode_ci NOT NULL,
  `phone` varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `academic_department_id` int NOT NULL,
  PRIMARY KEY (`student_id`),
  UNIQUE KEY `email` (`email`),
  KEY `fk_students_academic_department` (`academic_department_id`),
  CONSTRAINT `fk_students_academic_department` FOREIGN KEY (`academic_department_id`) REFERENCES `academic_departments` (`academic_department_id`)
) ENGINE=InnoDB AUTO_INCREMENT=102 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping events for database 'college_complaints'
--

--
-- Dumping routines for database 'college_complaints'
--
/*!50003 DROP PROCEDURE IF EXISTS `update_complaint_status` */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = cp850 */ ;
/*!50003 SET character_set_results = cp850 */ ;
/*!50003 SET collation_connection  = cp850_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `update_complaint_status`(
    IN p_complaint_id INT,
    IN p_new_status VARCHAR(30)
)
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_current_status VARCHAR(30);

    
    SELECT COUNT(*)
    INTO v_count
    FROM complaints
    WHERE complaint_id = p_complaint_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Complaint does not exist';

    ELSEIF p_new_status NOT IN (
        'Submitted',
        'In Progress',
        'Resolved',
        'Rejected'
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Invalid complaint status';

    ELSE
        SELECT status
        INTO v_current_status
        FROM complaints
        WHERE complaint_id = p_complaint_id;

        
        IF v_current_status IN ('Resolved', 'Rejected')
           AND p_new_status <> v_current_status THEN

            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot change a final complaint status';

        ELSE
            UPDATE complaints
            SET
                status = p_new_status,
                resolved_at = CASE
                    WHEN p_new_status = 'Resolved' THEN
                        COALESCE(resolved_at, NOW())
                    ELSE NULL
                END
            WHERE complaint_id = p_complaint_id;
        END IF;
    END IF;
END ;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;

--
-- Final view structure for view `complaint_details`
--

/*!50001 DROP VIEW IF EXISTS `complaint_details`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = cp850 */;
/*!50001 SET character_set_results     = cp850 */;
/*!50001 SET collation_connection      = cp850_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `complaint_details` AS select `c`.`complaint_id` AS `complaint_id`,`c`.`title` AS `title`,`s`.`full_name` AS `student_name`,`s`.`email` AS `student_email`,`ad`.`department_name` AS `academic_department`,`d`.`department_name` AS `responsible_department`,`c`.`category` AS `category`,`c`.`priority` AS `priority`,`c`.`status` AS `status`,`c`.`created_at` AS `created_at` from (((`complaints` `c` join `students` `s` on((`c`.`student_id` = `s`.`student_id`))) join `academic_departments` `ad` on((`s`.`academic_department_id` = `ad`.`academic_department_id`))) join `departments` `d` on((`c`.`department_id` = `d`.`department_id`))) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `department_complaint_summary`
--

/*!50001 DROP VIEW IF EXISTS `department_complaint_summary`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = cp850 */;
/*!50001 SET character_set_results     = cp850 */;
/*!50001 SET collation_connection      = cp850_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `department_complaint_summary` AS select `d`.`department_name` AS `department_name`,count(`c`.`complaint_id`) AS `total_complaints`,coalesce(sum((`c`.`status` = 'Resolved')),0) AS `resolved_complaints`,coalesce(sum((`c`.`status` in ('Submitted','In Progress'))),0) AS `pending_complaints` from (`departments` `d` left join `complaints` `c` on((`d`.`department_id` = `c`.`department_id`))) group by `d`.`department_id`,`d`.`department_name` */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `open_complaints`
--

/*!50001 DROP VIEW IF EXISTS `open_complaints`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = cp850 */;
/*!50001 SET character_set_results     = cp850 */;
/*!50001 SET collation_connection      = cp850_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `open_complaints` AS select `complaint_details`.`complaint_id` AS `complaint_id`,`complaint_details`.`title` AS `title`,`complaint_details`.`student_name` AS `student_name`,`complaint_details`.`student_email` AS `student_email`,`complaint_details`.`academic_department` AS `academic_department`,`complaint_details`.`responsible_department` AS `responsible_department`,`complaint_details`.`category` AS `category`,`complaint_details`.`priority` AS `priority`,`complaint_details`.`status` AS `status`,`complaint_details`.`created_at` AS `created_at` from `complaint_details` where (`complaint_details`.`status` in ('Submitted','In Progress')) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;

--
-- Final view structure for view `pending_complaints`
--

/*!50001 DROP VIEW IF EXISTS `pending_complaints`*/;
/*!50001 SET @saved_cs_client          = @@character_set_client */;
/*!50001 SET @saved_cs_results         = @@character_set_results */;
/*!50001 SET @saved_col_connection     = @@collation_connection */;
/*!50001 SET character_set_client      = cp850 */;
/*!50001 SET character_set_results     = cp850 */;
/*!50001 SET collation_connection      = cp850_general_ci */;
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `pending_complaints` AS select `c`.`complaint_id` AS `complaint_id`,`c`.`title` AS `title`,`c`.`category` AS `category`,`c`.`priority` AS `priority`,`c`.`status` AS `status`,`c`.`created_at` AS `created_at`,`s`.`full_name` AS `student_name`,`d`.`department_name` AS `department_name` from ((`complaints` `c` join `students` `s` on((`c`.`student_id` = `s`.`student_id`))) join `departments` `d` on((`c`.`department_id` = `d`.`department_id`))) where (`c`.`status` in ('Submitted','In Progress')) */;
/*!50001 SET character_set_client      = @saved_cs_client */;
/*!50001 SET character_set_results     = @saved_cs_results */;
/*!50001 SET collation_connection      = @saved_col_connection */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-11-13 18:06:02
