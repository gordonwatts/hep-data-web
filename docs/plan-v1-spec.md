# HEP Data LLM Web Frontend Specification (V1)

## Overview

This project provides a web frontend for the existing `hep-data-llm` plotting and analysis system.

The goal is to create a lightweight, beginner-friendly web application where ATLAS collaborators can submit natural-language plotting requests and receive:

* Generated plots
* Generated source code
* Persistent history of prior requests
* Downloadable artifacts

The frontend should reuse the existing `hep-data-llm` backend capabilities as much as possible and should avoid introducing new backend semantics or analysis logic.

The frontend is intended primarily as:

* A beginner-friendly analysis assistance tool
* A lightweight analysis request portal
* A persistent corpus of prompts/results
* A teaching and onboarding tool

This project does not attempt to redesign or replace the backend plotting engine.

---

# Target Audience

Initial audience:

* ATLAS collaborators only
* Primarily beginner analysts and users learning the workflow

Future authentication systems may include:

* CERN SSO
* Keycloak/OIDC

However, the initial implementation should use GitHub OAuth.

---

# Authentication and Authorization

## Authentication

Authentication is performed using GitHub OAuth.

## User Approval Workflow

New users are not automatically granted access.

Workflow:

1. User lands on site
2. User authenticates with GitHub
3. If user is unknown:

   * User account enters pending state
   * Email notification is sent to all admins
4. Admin visits approval page
5. Admin approves or rejects account
6. Email notification is sent to user
7. On next login, approved user gains access

## Roles

The system supports at least two roles:

* `user`
* `admin` (or `owner`)

## Permissions

Regular users:

* Can only see their own jobs/results
* Cannot see other users' prompts, plots, or code

Admins:

* Can inspect all jobs
* Can inspect queue
* Can cancel jobs
* Can delete jobs
* Can approve/reject users

All prompts, generated code, and results are private by default.

---

# Backend Integration

The system uses the existing backend implementation from:

[https://github.com/gordonwatts/hep-data-llm](https://github.com/gordonwatts/hep-data-llm)

The web application should:

* Reuse existing backend behavior
* Reuse existing backend workflow semantics
* Reuse existing backend examples/questions
* Avoid introducing new plotting semantics
* Avoid requiring backend modifications whenever possible

The frontend and backend are tightly integrated at deployment time.

The container build should pin the specific `hep-data-llm` version used via explicit dependency installation.

The deployment should not automatically track latest backend HEAD.

---

# Data Model and Dataset Behavior

The backend operates only on ATLAS datasets available through Rucio.

The frontend does not introduce additional dataset abstractions.

## Default Dataset

If the user does not specify a dataset:

* The system automatically injects a default ATLAS Open Data JZ dataset
* The default dataset should be taken from the existing example questions in the `hep-data-llm` repository

## Dataset Specification

Datasets remain primarily natural-language driven.

The frontend does not require a dedicated dataset picker in V1.

---

# Backend Profiles

The frontend exposes the existing backend profile mechanism directly.

## Profile Selection

A dropdown selector allows the user to choose the backend profile.

Profiles correspond directly to the existing CLI/Python profile options.

Default profile:

* ServiceX + Awkward backend

Additional selectable profile:

* RDF backend

The frontend should not invent new execution abstractions.

---

# Job Execution Model

## Asynchronous Execution

All jobs execute asynchronously.

The web request must never block on analysis execution.

Workflow:

1. User submits prompt
2. Job is queued
3. Worker thread/process executes job asynchronously
4. User may disconnect/reconnect safely
5. Completion email is sent when finished

## Worker Model

Initial implementation:

* Single active worker globally
* One job executes at a time
* Additional jobs remain queued

The implementation may:

* Use a worker thread
* Use a worker process
* Exist within the same container as the web server

The execution system should not execute jobs directly inside HTTP request handlers.

## Queue

The queue is persistent.

Users should be able to see:

* Queue depth
* Job status
* Queue position

Queue states should include at least:

* queued
* running
* completed
* failed

## Queue Limits

* Multiple queued jobs per user are allowed
* Global queue limit: 20 jobs

If queue is full:

* Reject new submissions
* Display friendly message such as:

  * "System appears busy or jammed, please try again later"

---

# Container Execution

The existing backend execution isolation model should be preserved.

Current backend behavior:

* One Docker container launched per plot/job execution

The frontend should preserve this behavior whenever possible.

The web deployment environment may require adaptations, but backend execution semantics should remain unchanged if feasible.

---

# User Interface

## Overall UX Philosophy

The interface should be:

* Lightweight
* Beginner-friendly
* Minimal cognitive overhead
* Natural-language centered

The application should NOT feel like:

* A notebook environment
* A complex analysis configuration portal
* A workflow orchestration system

## Main Page

The main page should use a minimal chat-style interaction model.

Primary UI element:

* Natural-language prompt input box

Secondary controls:

* Backend profile dropdown
* Small number of workflow-related options

The homepage should also include:

* User history table
* Small set of example questions/prompts

## Example Questions

Example prompts should:

* Be sourced from the existing `question.yaml` examples in `hep-data-llm`
* Be beginner-oriented
* Be clickable/populate the input box

The frontend should reuse backend examples rather than invent new frontend-only tutorials.

---

# Job History Table

The history table should include:

* Submission timestamp
* Current status
* Original prompt
* Dataset used/resolved
* Backend profile used
* Queue position/status
* Runtime duration
* Completion timestamp
* Result links
* Failure indication/message

Likely actions include:

* View
* Download plot
* Download code
* Clone/edit/resubmit

---

# Result Pages

Each job should have a separate result page accessible via a "View" link/button.

The result page should display:

* Plot preview(s)
* Generated code
* Status/error information
* Download links
* Basic metadata

The homepage should remain uncluttered.

---

# Output Artifacts

## User-visible Outputs

Users should be able to:

* View final generated code inline
* Download final generated code
* View generated plot(s) inline
* Download generated plot(s)

## Artifact Semantics

There is exactly one primary downloadable artifact per job.

There may be multiple generated images displayed inline.

The frontend should support:

* Multiple inline images
* Single canonical downloadable artifact

## Code Display

Generated code should:

* Be viewable inline
* Use an existing syntax-highlighting/viewer framework
* Avoid requiring custom editor/viewer work

---

# Failure Handling

Failed jobs remain persistent history entries.

When a job fails, the user should be able to see:

* Final generated source code
* Failure/error message

Users should NOT necessarily see:

* Intermediate repair attempts
* Internal prompts
* Full orchestration traces
* Detailed internal logs

---

# Job Reuse Semantics

Users should NOT be able to:

* Rerun an old job exactly as-is

Users SHOULD be able to:

* Clone a previous job
* Edit a previous prompt
* Resubmit modified prompts

The system is not intended to provide strict reproducibility semantics in V1.

---

# Email Notifications

Emails are sent only for terminal job states.

Notifications include:

* Job completed successfully
* Job failed

Emails should contain:

* Status notification
* Link to the user's jobs page

Emails should NOT include:

* Attachments
* Intermediate queue notifications
* Job-start notifications

---

# Persistence and Storage

## Persistence Model

Jobs, prompts, generated code, and plots persist indefinitely.

The expected storage footprint is modest.

No automatic deletion or expiration policy is required in V1.

## Database Requirements

The system requires persistent structured storage.

Persistent data likely includes:

* Users
* Roles
* Approval state
* Jobs
* Queue state
* Metadata
* Artifact references

Database state must survive container restarts.

Persistent storage should therefore exist outside ephemeral containers.

---

# Deployment Model

## Initial Deployment

Initial deployment and development should target:

* Laptop/workstation environments
* Single-node deployment
* Docker-first workflow

Primary UX goal:

* Extremely simple deployment
* `docker compose up` style operation

## Future Deployment

Future deployment targets may include:

* Azure
* Cloud VM/container hosting
* Institutional infrastructure

However:

* Cloud-native orchestration complexity is NOT required in V1

## Containerization

The implementation should support:

* Dockerized deployment
* Docker Compose orchestration if multiple containers are used

---

# Administrative Interface

Admins should have access to:

* Global job inspection
* Queue inspection
* Job cancellation
* Job deletion
* User approval/rejection

Sophisticated operational dashboards are not required in V1.

---

# Architectural Philosophy

The system should be:

* Operationally simple
* Easy to deploy locally
* Beginner-friendly
* Persistent
* Minimal in UI complexity

The frontend should:

* Reuse backend semantics whenever possible
* Avoid inventing new analysis abstractions
* Avoid unnecessary backend modifications
* Keep operational complexity low

The architecture should favor:

* Monolithic application structure
* Asynchronous worker semantics
* Simple persistent storage
* Container-based execution isolation

Over:

* Distributed microservices
* Complex orchestration systems
* Notebook-like workflows
* Large-scale infrastructure assumptions
