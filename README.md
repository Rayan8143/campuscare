# CampusCare — College Complaint Management System
## Setup on Windows
1. Install MySQL Server 8.0 and Python 3.10+.
2. Open Command Prompt in this extracted folder.
3. Import schema: `mysql -u root -p < schema.sql`
4. Log in: `mysql -u root -p`, then run:
   `CREATE USER IF NOT EXISTS 'complaint_app'@'localhost' IDENTIFIED BY 'ChooseYourPassword';`
   `ALTER USER 'complaint_app'@'localhost' IDENTIFIED BY 'ChooseYourPassword';`
   `GRANT ALL PRIVILEGES ON college_complaints.* TO 'complaint_app'@'localhost';`
   `EXIT;`
5. Install packages: `python -m pip install -r requirements.txt`
6. Set credentials in the same Command Prompt (use the password you chose):
   `set DB_USER=complaint_app`
   `set DB_PASSWORD=ChooseYourPassword`
   `set DB_NAME=college_complaints`
7. Run `python app.py` and visit http://127.0.0.1:5000.
Stop the server with Ctrl+C. This is a local academic prototype, not production-ready.
\n\n## Design note\nThe original CampusCare dashboard layout and stylesheet have been restored. The Flask backend remains compatible with the rebuilt MySQL schema.\n