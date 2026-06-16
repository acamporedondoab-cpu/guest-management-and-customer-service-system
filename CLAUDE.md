# Campground Guest Management Demo

## Goal

Build a demo application that demonstrates a scalable campground guest management architecture aligned with the following stack:

* React
* Supabase
* Make.com
* GoHighLevel

This is NOT a production reservation system.

The purpose is to demonstrate:

1. Reservation capture
2. Guest data storage
3. CRM synchronization
4. Automated communications
5. Loyalty tracking
6. Future reporting and AI readiness

---

## Architecture

Guest Reservation Form
↓
Supabase Database
↓
Webhook Event
↓
Make.com Automation
↓
GoHighLevel CRM
↓
Email + SMS Automation
↓
Loyalty Tracking

---

## Frontend Requirements

### Reservation Page

Fields:

* First Name
* Last Name
* Email
* Phone
* Site Number
* Check In Date
* Check Out Date
* Number of Guests
* Notes

Button:

* Book Reservation

After submission:

* Save reservation into Supabase
* Show success confirmation

---

### Dashboard Page

Show:

#### KPI Cards

* Total Guests
* Total Reservations
* Returning Guests
* Estimated Revenue

#### Guests Table

Columns:

* Name
* Email
* Phone
* Total Visits
* Loyalty Tier

#### Reservations Table

Columns:

* Reservation ID
* Guest
* Site Number
* Check In
* Check Out
* Status

---

## Supabase Schema

### guests

* id
* first_name
* last_name
* email
* phone
* created_at

### reservations

* id
* guest_id
* site_number
* check_in
* check_out
* total_amount
* status
* created_at

### loyalty

* id
* guest_id
* total_visits
* total_spend
* tier
* last_visit

---

## Loyalty Logic

Automatically calculate:

Bronze:
1-2 visits

Silver:
3-5 visits

Gold:
6+ visits

---

## Demo Automation Flow

Reservation Created
↓
Supabase
↓
Webhook Payload
↓
Make.com
↓
Create/Update Contact in GoHighLevel
↓
Send Welcome Email
↓
Send Welcome SMS
↓
Update Loyalty Record

---

## UI Requirements

* Modern campground theme
* Clean SaaS dashboard
* Responsive design
* Tailwind CSS
* Component-based architecture

---

## Deliverables

1. React Application
2. Supabase SQL Schema
3. Environment Variable Setup
4. Sample Webhook Payload
5. Architecture Diagram
6. README explaining the complete workflow
