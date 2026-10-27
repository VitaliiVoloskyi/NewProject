# Architecture: containers (C4, level 2)

```mermaid
flowchart TB
    user(["<b>Team lead</b><br/>[Person]<br/>Plans meetings and their agendas"])

    subgraph aws ["Spry on AWS (us-east-1)"]
        spa["<b>Web app</b><br/>[React, S3 + CloudFront]<br/>Calendar, meetings, agendas,<br/>Paste an agenda"]
        cognito["<b>User pool</b><br/>[Amazon Cognito]<br/>Sign-in, ID tokens"]
        parser["<b>Agenda parser</b><br/>[Python, Lambda + function URL, no VPC]<br/>Turns pasted text into a suggested agenda.<br/>Reads no data, writes nothing"]
        subgraph vpc ["VPC, no NAT"]
            api["<b>API</b><br/>[FastAPI, Lambda + function URL]<br/>Meetings, participants, agendas;<br/>validates every write"]
            db[("<b>Database</b><br/>[RDS PostgreSQL]<br/>meetings.agenda,<br/>meetings.agenda_ai_suggestion")]
            builder["<b>Report builder</b><br/>[Python, Lambda]"]
        end
        queue["<b>Report requests</b><br/>[SQS + DLQ]"]
        scheduler["<b>Weekly schedule</b><br/>[EventBridge Scheduler]"]
        bucket["<b>Reports</b><br/>[S3]"]
        mailer["<b>Report mailer</b><br/>[Lambda, no VPC]"]
    end

    bedrock["<b>Claude Opus 5.5</b><br/>[Amazon Bedrock, Messages API]<br/>External model"]
    ses["<b>Email</b><br/>[Amazon SES]"]

    user -->|"uses [HTTPS]"| spa
    spa -->|"signs in [OIDC + PKCE]"| cognito
    spa ==>|"<b>parse</b>: text, today, tz<br/>[POST, Bearer ID token]"| parser
    parser ==>|"record_agenda tool call<br/>[bedrock-mantle, IAM role]"| bedrock
    spa ==>|"<b>save</b>: agenda + ai_suggestion<br/>[PUT /api/meetings/{id}/agenda]"| api
    api ==>|"writes [SQL]"| db
    parser -.->|"verifies tokens [JWKS]"| cognito
    api -.->|"verifies tokens [JWKS]"| cognito
    scheduler --> queue --> builder
    builder -->|reads| db
    builder -->|"reports/&lt;week&gt;.csv [gateway endpoint]"| bucket
    bucket -->|ObjectCreated| mailer --> ses
```

The two thick paths are the Paste an agenda feature. **Parse** goes from the browser to the
parser and Bedrock, outside the VPC, and returns only a suggestion. **Save** goes from the
browser to the API and the database inside the VPC, on the path every other write already
takes. The model has no route to the database. See
[ADR 0006](adr/0006-llm-agenda-parsing.md).
