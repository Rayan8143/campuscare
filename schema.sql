CREATE DATABASE IF NOT EXISTS college_complaints CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE college_complaints;
CREATE TABLE IF NOT EXISTS students(student_id INT AUTO_INCREMENT PRIMARY KEY,full_name VARCHAR(100) NOT NULL,email VARCHAR(120) NOT NULL UNIQUE,phone VARCHAR(20),department VARCHAR(100));
CREATE TABLE IF NOT EXISTS departments(department_id INT AUTO_INCREMENT PRIMARY KEY,department_name VARCHAR(100) NOT NULL UNIQUE,description VARCHAR(255));
CREATE TABLE IF NOT EXISTS staff(staff_id INT AUTO_INCREMENT PRIMARY KEY,department_id INT NOT NULL,full_name VARCHAR(100) NOT NULL,email VARCHAR(120) NOT NULL UNIQUE,FOREIGN KEY(department_id) REFERENCES departments(department_id));
CREATE TABLE IF NOT EXISTS complaints(complaint_id INT AUTO_INCREMENT PRIMARY KEY,student_id INT NOT NULL,department_id INT NOT NULL,assigned_staff_id INT NULL,title VARCHAR(180) NOT NULL,description TEXT NOT NULL,category VARCHAR(50) NOT NULL,priority ENUM('Low','Medium','High') NOT NULL DEFAULT 'Medium',status ENUM('Submitted','In Progress','Resolved','Rejected') NOT NULL DEFAULT 'Submitted',created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,resolved_at DATETIME NULL,FOREIGN KEY(student_id) REFERENCES students(student_id),FOREIGN KEY(department_id) REFERENCES departments(department_id),FOREIGN KEY(assigned_staff_id) REFERENCES staff(staff_id));
CREATE TABLE IF NOT EXISTS complaint_history(history_id INT AUTO_INCREMENT PRIMARY KEY,complaint_id INT NOT NULL,old_status VARCHAR(30),new_status VARCHAR(30) NOT NULL,changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,remarks VARCHAR(255),FOREIGN KEY(complaint_id) REFERENCES complaints(complaint_id) ON DELETE CASCADE);
CREATE OR REPLACE VIEW pending_complaints AS SELECT c.complaint_id,c.title,c.category,c.priority,c.status,c.created_at,s.full_name AS student_name,d.department_name FROM complaints c JOIN students s ON c.student_id=s.student_id JOIN departments d ON c.department_id=d.department_id WHERE c.status IN ('Submitted','In Progress');
DROP TRIGGER IF EXISTS trg_complaint_status_history;
DELIMITER $$
CREATE TRIGGER trg_complaint_status_history AFTER UPDATE ON complaints FOR EACH ROW
BEGIN
 IF OLD.status <> NEW.status THEN
 INSERT INTO complaint_history(complaint_id,old_status,new_status,remarks) VALUES(NEW.complaint_id,OLD.status,NEW.status,'Status updated from dashboard');
 END IF;
END$$
DELIMITER ;
INSERT IGNORE INTO departments(department_id,department_name,description) VALUES(1,'Maintenance','Buildings and electrical repairs'),(2,'IT Support','Network and computer issues'),(3,'Hostel Office','Hostel facilities'),(4,'Laboratory','Lab equipment'),(5,'Housekeeping','Cleanliness');
INSERT IGNORE INTO staff(staff_id,department_id,full_name,email) VALUES(1,3,'Hostel Support Staff','hostel_office@example.edu'),(2,5,'Housekeeping Staff','housekeeping@example.edu'),(3,2,'IT Support Staff','it_support@example.edu'),(4,4,'Laboratory Staff','laboratory@example.edu'),(5,1,'Maintenance Staff','maintenance@example.edu');
INSERT IGNORE INTO students(student_id,full_name,email,phone,department) VALUES(1,'Meghana Reddy','meghana@example.edu','9000000001','CSE'),(2,'Chintu Kumar','chintu@example.edu','9000000002','CSE'),(3,'Bunty Babu','bunty@example.edu','9000000003','CSE');
INSERT IGNORE INTO complaints(complaint_id,student_id,department_id,title,description,category,priority,status) VALUES(1,1,2,'Wi-Fi disconnects frequently','Wi-Fi disconnects frequently in the library','Network','High','In Progress'),(2,2,1,'Broken classroom fan','The fan in the classroom is not working','Infrastructure','Medium','Submitted'),(3,3,4,'Lab computer not starting','A laboratory computer does not power on','Laboratory','High','Resolved');
