# Self-Hosting n8n on Google Cloud Run: Complete Guide #

This guide will walk you through the process of self-hosting n8n.io on Google Cloud Run with PostgreSQL persistence and setting up Google OAuth credentials for services like Google Sheets.

By following this guide, you'll have a fully functional n8n instance running on Google Cloud Run with PostgreSQL persistence and the ability to connect to Google services via OAuth.

## Overview ##

n8n is a powerful workflow automation platform that can be self-hosted. This guide uses:

* [Google Cloud Run](https://cloud.google.com/run?hl=en) for serverless container hosting

* [Cloud SQL PostgreSQL](https://cloud.google.com/sql/docs/postgres) for database persistence

* [Google Auth Platform](https://support.google.com/cloud/answer/15544987?hl=en) for connecting to Google services

Self-hosting n8n gives you complete control over your automation workflows and data. Unlike the cloud version, self-hosting ensures your sensitive workflow data stays within your infrastructure and allows unlimited executions without monthly subscription fees. Google Cloud Run is an ideal hosting platform because it provides serverless scalability while only charging for the resources you actually use.

## Prerequisites ##

Before starting, you'll need:

* A Google Cloud account

* gcloud CLI installed and configured

* Basic familiarity with Docker and command line

* A domain name (optional, but recommended for production use)

The gcloud CLI is essential as it allows us to script the entire deployment process without using the web console. Docker knowledge is needed because n8n runs as a containerized application, ensuring consistent behavior across different environments. While a custom domain is optional, it's recommended for production use as it provides a consistent endpoint for your workflows, especially important if you're using webhooks from external services.

## Step 1: Set Up Your Google Cloud Project ##

First, create and configure your Google Cloud project:

```bash
# Set your Google Cloud project ID
export PROJECT_ID="your-project-id"
export REGION="europe-west2"  # Choose your preferred region

# Log in to gcloud
gcloud auth login

# Set your active project
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable artifactregistry.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable sqladmin.googleapis.com
gcloud services enable secretmanager.googleapis.com
```

These commands establish your project environment and enable the necessary Google Cloud APIs. Artifact Registry stores your Docker images, Cloud Run hosts your containerised application, Cloud SQL provides the database, and Secret Manager securely stores sensitive credentials. Enabling these services upfront prevents deployment errors later in the process.

## Step 2: Create a Custom Dockerfile and Startup Script for n8n ##

Instead of a minimal Dockerfile, we need to create a custom setup to handle the specific requirements of running n8n on Cloud Run. This involves two files:

1. `startup.sh` - a startup script
2. `Dockerfile` - a modified Dockerfile that incorporates this script

### Why This Custom Setup is Essential ###

The startup script specifically addresses a key architectural challenge: Google Cloud Run injects its own `PORT` environment variable and expects containers to honour it, while n8n has its own port configuration system. Without this bridge, the two systems would be incompatible.

This customised setup solves several critical issues when running n8n on Cloud Run:

* **Port Mapping**: Cloud Run injects a PORT environment variable that containers must listen on, but n8n uses N8N_PORT instead. Our startup script bridges this gap by mapping one to the other.

* **Debugging Support**: The script outputs key environment variables, making troubleshooting much easier if deployment issues occur.

* **Permission Management**: We temporarily switch to the root user to set permissions on our script, then return to the non-root node user (a security best practice).

* **Execution Format**: Using /bin/sh explicitly helps prevent "exec format errors" that commonly occur with scripts created on different operating systems (especially Windows).

Without this custom setup, n8n would fail to start** properly in Cloud Run, and you would encounter errors like "container failed to start", or "exec format error", or "Cannot GET /".

This approach maintains compatibility with both n8n's requirements and Cloud Run's serverless container environment.

#### Troubleshooting this Step ###

If you run into issues stemming from this when building the Dockerfile you can try:

* Check the line endings of `startup.sh` are unix compatible i.e. LF (not CLRF)
* Ensure the file is executable by running `chmod +x /startup.sh` before building

## Step 3: Set Up a Container Repository ##

Google Artifact Registry provides a secure, private repository for your Docker images with integrated authentication through your Google Cloud account. We specifically build for the linux/amd64 platform to ensure compatibility with Cloud Run's infrastructure, which is particularly important if you're developing on ARM-based systems like M1/M2 Macs.

Create and configure a Google Artifact Registry repository:

```bash
# Create a repository in Artifact Registry
gcloud artifacts repositories create n8n-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for n8n workflow images"

# Configure Docker to use gcloud as a credential helper
gcloud auth configure-docker $REGION-docker.pkg.dev

# Build and push your image
docker build --platform linux/amd64 -t $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest
```

## Step 4: Set Up Cloud SQL PostgreSQL Instance ##

We're using the db-f1-micro tier and minimal storage configuration to keep costs low while still providing reliable database service. PostgreSQL is the recommended database for n8n production deployments as it offers better performance and reliability than SQLite (n8n's default). The `ZONAL` availability type is chosen as a cost-effective option for non-critical deployments

Create a PostgreSQL instance and database for n8n:

```bash
# Create a Cloud SQL instance (lowest cost tier)
gcloud sql instances create n8n-db \
    --database-version=POSTGRES_13 \
    --tier=db-f1-micro \
    --region=$REGION \
    --root-password="supersecure-rootpassword" \
    --storage-size=10GB \
    --availability-type=ZONAL \
    --no-backup \
    --storage-type=HDD

# Create a database
gcloud sql databases create n8n --instance=n8n-db

# Create a user for n8n
gcloud sql users create n8n-user \
    --instance=n8n-db \
    --password="supersecure-userpassword"
```

## Step 5: Create Secrets for Sensitive Data ##

Secret Manager is used instead of environment variables for sensitive data like passwords and encryption keys. This separation of configuration from secrets follows security best practices and prevents credentials from appearing in deployment logs or configuration files. The encryption key is particularly important as it protects all credentials stored within your n8n instance.

Store sensitive information like passwords in Secret Manager:

```bash
# Create a secret for the database password
echo -n "supersecure-userpassword" | \
    gcloud secrets create n8n-db-password \
    --data-file=- \
    --replication-policy="automatic"

# Create a secret for n8n encryption key
echo -n "your-random-encryption-key" | \
    gcloud secrets create n8n-encryption-key \
    --data-file=- \
    --replication-policy="automatic"
```

## Step 6: Create a Service Account for Cloud Run ##

Creating a dedicated service account with minimal permissions follows the principle of least privilege (PoLP) - a security best practice that reduces your attack surface. The service account needs specific access to Secret Manager to read your secrets and to Cloud SQL to establish database connections, but doesn't require broader project permissions."

Create and configure a service account for your n8n service:

```bash
# Create a service account
gcloud iam service-accounts create n8n-service-account \
    --display-name="n8n Service Account"

# Grant access to secrets
gcloud secrets add-iam-policy-binding n8n-db-password \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding n8n-encryption-key \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

# Grant Cloud SQL Client role
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"
```

## Step 7: Deploy to Cloud Run ##

Now deploy n8n to Cloud Run with the correct environment variables:

```bash
# Get the connection name for your Cloud SQL instance
export SQL_CONNECTION=$(gcloud sql instances describe n8n-db --format="value(connectionName)")

# Deploy to Cloud Run
gcloud run deploy n8n \
    --image=$REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest \
    --platform=managed \
    --region=$REGION \
    --allow-unauthenticated \
    --port=5678 \
    --cpu=1 \
    --memory=2Gi \
    --min-instances=0 \
    --max-instances=1 \
    --set-env-vars="N8N_PATH=/,N8N_PORT=443,N8N_PROTOCOL=https,DB_TYPE=postgresdb,DB_POSTGRESDB_DATABASE=n8n,DB_POSTGRESDB_USER=n8n-user,DB_POSTGRESDB_HOST=/cloudsql/$SQL_CONNECTION,DB_POSTGRESDB_PORT=5432,DB_POSTGRESDB_SCHEMA=public,N8N_USER_FOLDER=/home/node/.n8n,EXECUTIONS_PROCESS=main,EXECUTIONS_MODE=regular,GENERIC_TIMEZONE=UTC,QUEUE_HEALTH_CHECK_ACTIVE=true" \
    --set-secrets="DB_POSTGRESDB_PASSWORD=n8n-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest" \
    --add-cloudsql-instances=$SQL_CONNECTION \
    --service-account=n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

After deployment, Cloud Run will provide a URL for your n8n instance. Note this URL as you'll need it for the OAuth configuration.

### n8n Google Cloud Run Environment Variables ###

Below is a comprehensive table of all environment variables used in our n8n deployment on Google Cloud Run:

```md
|Environment Variable     |Value                        |Description                           |Why It's Needed                                                                                 |
|-------------------------|-----------------------------|--------------------------------------|------------------------------------------------------------------------------------------------|
|N8N_PATH                 |/                            |Base path where n8n will be accessible|Defines the root path for all n8n endpoints                                                     |
|N8N_PORT                 |443                          |External port for n8n                 |Set to 443 for proper OAuth callback URL generation (despite internal container port being 5678)|
|N8N_PROTOCOL             |https                        |Protocol used for external access     |Required for secure connections and OAuth flows                                                 |
|DB_TYPE                  |postgresdb                   |Database type for n8n                 |Must be exactly "postgresdb" (not postgresql) for proper database connection                    |
|DB_POSTGRESDB_DATABASE   |n8n                          |Name of the PostgreSQL database       |Specifies which database n8n should connect to                                                  |
|DB_POSTGRESDB_USER       |n8n-user                     |Database user name                    |Required for database authentication                                                            |
|DB_POSTGRESDB_HOST       |/cloudsql/[connection-name]  |PostgreSQL connection path            |Uses Cloud SQL Unix socket format for secure connections                                        |
|DB_POSTGRESDB_PORT       |5432                         |PostgreSQL port                       |Standard PostgreSQL port for connections                                                        |
|DB_POSTGRESDB_SCHEMA     |public                       |PostgreSQL schema                     |Required for n8n to properly initialize database tables                                         |
|N8N_USER_FOLDER          |/home/node/.n8n              |Location for n8n data                 |Defines where n8n stores workflow data and credentials                                          |
|GENERIC_TIMEZONE         |UTC                          |Default timezone                      |Ensures consistent time handling across deployments                                             |
|EXECUTIONS_PROCESS       |main                         |Execution mode for workflows          |Set to "main" for single-container deployment (vs. queue for multi-container)                   |
|EXECUTIONS_MODE          |regular                      |How executions are processed          |Controls workflow execution behavior                                                            |
|N8N_LOG_LEVEL            |debug                        |Logging verbosity                     |Set to debug for troubleshooting deployment issues                                              |
|QUEUE_HEALTH_CHECK_ACTIVE|true                         |Enables health check endpoint         |Critical for Cloud Run to verify container health                                               |
|N8N_HOST                 |[your-domain].run.app        |Public hostname of n8n                |Required for proper webhook and OAuth URL generation                                            |
|N8N_WEBHOOK_URL          |https://[your-domain].run.app|Full webhook URL                      |Needed for external services to call n8n webhooks                                               |
|N8N_EDITOR_BASE_URL      |https://[your-domain].run.app|Base URL for editor frontend          |Critical for proper OAuth redirect URL generation                                               |
|DB_POSTGRESDB_PASSWORD   |(from secret)                |Database user password                |Stored securely in Secret Manager                                                               |
|N8N_ENCRYPTION_KEY       |(from secret)                |Key for encrypting credentials        |Ensures secure storage of sensitive information in the database                                 |
```

The deployment configuration balances performance and cost-effectiveness. Setting min-instances to 0 allows the service to scale down to zero when not in use (saving money) while setting max-instances to 1 prevents it scaling out of control (and possibly concurrent executions that could cause database conflicts). The CPU and memory allocation provides enough resources for moderate workflow complexity without excessive costs.

#### Special Notes: ####

* The `PORT` variable (5678) shouldn't be explicitly set as it's injected by Cloud Run automatically

* The Cloud Run instance must map the internal container port (5678) to the port specified by Cloud Run

* Setting `N8N_PORT=443` helps generate correct external URLs while the container still listens on 5678 internally

* `QUEUE_HEALTH_CHECK_ACTIVE=true` creates an internal health endpoint that Cloud Run requires to verify container health

This configuration balances n8n's requirements with Google Cloud Run's serverless container environment.

## Step 8: Configure n8n for OAuth with Google Services ##

Once your n8n instance is running, you need to update the deployment with additional environment variables for proper OAuth functioning:

```bash
# Get your service URL (replace with your actual URL)
export SERVICE_URL="https://n8n-YOUR_ID.REGION.run.app"

# Update the deployment with proper URL configuration
gcloud run services update n8n \
    --region=$REGION \
    --set-env-vars="N8N_HOST=$(echo $SERVICE_URL | sed 's/https:\/\///'),N8N_WEBHOOK_URL=$SERVICE_URL,N8N_EDITOR_BASE_URL=$SERVICE_URL"
```

These environment variables are crucial for OAuth functionality because they tell n8n how to construct callback URLs during the authentication flow. Without these, OAuth services wouldn't be able to redirect back to your n8n instance correctly after authentication, resulting in 'redirect_uri_mismatch' errors.

## Step 9: Set Up Google OAuth Credentials ##

To connect n8n with Google services like Google Sheets, follow these steps:

1. Access the Google Cloud Console:

    * Navigate to the Google Cloud Console

    * Select your project

2. Enable Required APIs:

    * Go to "APIs & Services" > "Library"

    * Search for and enable the APIs you need (e.g., "Google Sheets API", "Google Drive API")

3. Configure OAuth Consent Screen:

    * Go to "APIs & Services" > "OAuth consent screen"

    * Select "External" user type (or "Internal" if using Google Workspace)

    * Fill in the required information (App name, user support email, etc.)

    * Add test users if using External type

    * For scopes, for now add the following:
        * `https://googleapis.com/auth/drive.file`
        * `https://googleapis.com/auth/spreadsheets`

    > Note: The OAuth consent screen configuration determines how your application appears to users during authentication. Using 'External' type is necessary for personal projects, but requires adding test users during development. The scopes requested determine what level of access n8n will have to Google services - we request only the minimum necessary for working with Google Sheets.

4. Create OAuth Client ID:

    * Go to "APIs & Services" > "Credentials"

    * Click "CREATE CREDENTIALS" and select "OAuth client ID"

    * Select "Web application" as the application type

    * Add your n8n URL to "Authorized JavaScript origins":
    
        ```bash
        https://n8n-YOUR_ID.REGION.run.app
        ```

    * When creating credentials in n8n, it will show you the required redirect URL. Add this to "Authorized redirect URIs":

        ```bash
        https://n8n-YOUR_ID.REGION.run.app/rest/oauth2-credential/callback
        ```

    * Click "CREATE" to generate your client ID and client secret

5. Add Credentials to n8n:

    * In your n8n instance, create a new credential for Google Sheets

    * Select "OAuth2" as the authentication type

    * Copy your OAuth client ID and client secret from Google Cloud Console

    * Complete the authentication flow

## Troubleshooting ##

When deploying complex systems like n8n on Cloud Run, specific configuration details are critical. Here are solutions to the most common issues you might encounter, based on the exact error messages you'll see:

1. Container Fails to Start:

    * Check Cloud Run logs for specific error messages

    * Verify `DB_TYPE` is set to "postgresdb" (not "postgresql")

    * Ensure `QUEUE_HEALTH_CHECK_ACTIVE` is set to "true"

2. OAuth Redirect Issues:

    * Ensure `N8N_HOST`, `N8N_PORT`, and `N8N_EDITOR_BASE_URL` are correctly set

    * Verify redirect URIs in Google Cloud Console match exactly what n8n generates

    * Confirm `N8N_PORT` is set to 443 (not 5678) for external URL formatting

3. Database Connection Problems:

    * Check `DB_POSTGRESDB_HOST` format for Cloud SQL connections

    * Ensure service account has Cloud SQL Client role