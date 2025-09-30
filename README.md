# Automated CI/CD Pipeline for Securing Docker Images with Prisma Cloud

This guide provides a complete, end-to-end walkthrough for creating an automated CI/CD pipeline using AWS CodeBuild. The pipeline will pull code from a GitHub repository, embed the Prisma Cloud App-Embedded Defender into a Docker image, push the secured image to Amazon ECR, and deploy it to an Amazon EKS Fargate cluster.

This document incorporates extensive troubleshooting steps to ensure a smooth setup for a first-time user, from initial repository creation to final resource cleanup.

## **Goal** 🎯

By following this guide, you will build a system that automatically:

1.  Sets up a code repository and a serverless Kubernetes cluster.
2.  Builds a CI/CD pipeline that securely injects the Prisma Cloud defender.
3.  Deploys the secured application to your EKS cluster.

### **Prerequisites**

* An **AWS Account**
* A **GitHub Account**
* A **Docker Hub Account**
* A **Prisma Cloud Compute Account**

---

## **Step 1: Set Up Your GitHub Repository** 📁

First, we'll create a central repository for our application code and pipeline instructions.

1.  **Create a New Repository on GitHub**:
    * Go to GitHub, click the `+` icon, and select **New repository**.
    * Name it (e.g., `prisma-eks-pipeline`), select **Public**, and click **Create repository**.

2.  **Clone the Repository Locally**:
    * On the repository page, click the green **<> Code** button and copy the HTTPS URL.
    * Open a terminal on your computer and run:
        ```bash
        git clone COPIED_URL_HERE
        cd prisma-eks-pipeline
        ```

3.  **Create Application Files**: Inside the new folder, create the following files.

    * **`Dockerfile`**: This file is the recipe for your container. The `ENTRYPOINT` is a specific requirement for the Prisma scanner.
        ```dockerfile
        # Use a standard Nginx image as the base
        FROM nginx:alpine
        
        # Copy a custom index.html to the Nginx web root
        COPY index.html /usr/share/nginx/html
        
        # Expose port 80
        EXPOSE 80
        
        # Explicitly define the command to run when the container starts
        ENTRYPOINT ["nginx", "-g", "daemon off;"]
        ```

    * **`index.html`**: A simple webpage for testing.
        ```html
        <!DOCTYPE html>
        <html>
        <body>
            <h1>This application is secured by the Prisma Cloud App Embedded Defender!</h1>
        </body>
        </html>
        ```

    * Create a new folder named `k8s`. Inside it, create two files with the `.yaml` extension:

        * **`k8s/deployment.yaml`**:
            ```yaml
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: my-secure-app
            spec:
              replicas: 2
              selector:
                matchLabels:
                  app: my-secure-app
              template:
                metadata:
                  labels:
                    app: my-secure-app
                spec:
                  containers:
                  - name: my-secure-app
                    image: placeholder
                    ports:
                    - containerPort: 80
            ```

        * **`k8s/service.yaml`**:
            ```yaml
            apiVersion: v1
            kind: Service
            metadata:
              name: my-secure-app-service
            spec:
              type: LoadBalancer
              ports:
                - protocol: TCP
                  port: 80
                  targetPort: 80
              selector:
                app: my-secure-app
            ```

4.  **Push Files to GitHub**: From your terminal, run these commands to save your work.
    ```bash
    git add .
    git commit -m "Add initial application and Kubernetes files"
    git push
    ```

---

## **Step 2: Create the EKS Fargate Cluster** 🏗️

We'll use AWS CloudShell and `eksctl` to provision a serverless Kubernetes cluster.

1.  **Open AWS CloudShell**: In the AWS Console, click the CloudShell icon `[>_]`.

2.  **Install `eksctl`**: Run these two commands in CloudShell to install the official EKS command-line tool.
    ```bash
    curl --silent --location "[https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname](https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname) -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
    ```

3.  **Create the Cluster**: Run the following command. **This will take 15-20 minutes.**
    ```bash
    eksctl create cluster --name myDemoEKS \
    --region us-east-1 \
    --fargate
    ```

---

## **Step 3: Securely Store All Your Credentials** 🔑

We will use AWS Secrets Manager to store all necessary credentials in a single secret.

1.  **Generate a Docker Hub Access Token**: In Docker Hub, go to **Account Settings > Security** and create a **New Access Token** with "Read, Write, Delete" permissions. Copy the token.

2.  **Create a Single Secret for All Credentials**:
    * In **AWS Secrets Manager**, click **Store a new secret**.
    * Select **Other type of secret**.
    * Add four key-value pairs:
        * **Key**: `PRISMA_USER`, **Value**: *Your Prisma Cloud Access Key*
        * **Key**: `PRISMA_PASS`, **Value**: *Your Prisma Cloud Secret Key*
        * **Key**: `DOCKERHUB_USER`, **Value**: *Your Docker Hub Username*
        * **Key**: `DOCKERHUB_PASS`, **Value**: *The Docker Hub Access Token you just generated*
        * **Key**: `PRISMA_USER`, **Value**: *Your Prisma Cloud Access Key*

    * Name the secret `pipeline/credentials` and save it.

---

## **Step 4: Verify the `buildspec.json` Pipeline Script** 📜

The repository already contains the final, working `buildspec.json` file.

1.  In the GitHub repository, locate the **`buildspec.json`** file.
2.  Verify that its contents are correct. This file contains the complete, fully-tested set of commands for the pipeline.

---

## **Step 5: Create the IAM Role for CodeBuild** 🛡️

This role grants CodeBuild the specific permissions it needs.

1.  In **IAM > Roles**, click **Create role**.
2.  Select **AWS service** and **CodeBuild**.
3.  Attach these two **AWS managed policies**:
    * `AmazonEC2ContainerRegistryPowerUser`
    * `AmazonEKSClusterPolicy`
4.  Name the role `CodeBuild-PublicRepo-EKS-Prisma-Role` and create it.
5.  Find the role and click its name to edit it.
6.  On the **Permissions** tab, **Create inline policy**.
7.  Select the **JSON** tab and paste the following, replacing the placeholder ARN with the actual ARN of the single secret you created.
    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": "secretsmanager:GetSecretValue",
                "Resource": "ARN_FOR_PIPELINE_CREDENTIALS_SECRET_HERE"
            }
        ]
    }
    ```
8.  Name the policy `SecretsManagerAccessPolicy` and save it.
9.  Create **one more inline policy**:
    * **Service**: EKS
    * **Actions**: `DescribeCluster`
    * **Resources**: Specific. Add the ARN for your `myDemoEKS` cluster.
        * **To find the ARN:** In **CloudShell**, run:
            ```bash
            aws eks describe-cluster --name myDemoEKS --query "cluster.arn" --output text
            ```
    * Name the policy `EKSDescribeClusterPermission` and save.

---

## **Step 6: Manually Create the ECR Repository**

To prevent permissions issues, we will manually create the ECR repository.

1.  Navigate to **Elastic Container Registry (ECR)**.
2.  Click **Create repository**.
3.  For **Repository name**, enter `my-secure-app`.
4.  Click **Create repository**.

---

## **Step 7: Create and Authorize a Kubernetes Service Account** 🧑‍🔧

This is the most reliable way to grant deployment permissions.

1.  Open **AWS CloudShell**.
2.  Connect to your cluster: `aws eks --region us-east-1 update-kubeconfig --name myDemoEKS`
3.  Create the service account:
    ```bash
    kubectl create serviceaccount codebuild-deployer -n kube-system
    ```
4.  Give it cluster-admin rights:
    ```bash
    kubectl create clusterrolebinding codebuild-deployer-binding --clusterrole=cluster-admin --serviceaccount=kube-system:codebuild-deployer
    ```

---

## **Step 8: Create the CodeBuild Project** 🏗️

This is the final step where we connect all the pieces.

1.  In **CodeBuild**, click **Create build project**.
2.  **Project name:** `prisma-github-defender-pipeline`
3.  **Source:**
    * **Source provider:** **GitHub**.
    * Select **Public repository** and paste your repository's URL.
4.  **Environment:**
    * **Operating system:** **Ubuntu**.
    * **Runtime(s):** **Standard**.
    * **Image:** `aws/codebuild/standard:7.0` (or latest).
    * ✅ **Privileged:** **CHECK THIS BOX**.
    * **Service role:** Choose the `CodeBuild-PublicRepo-EKS-Prisma-Role` you created.
5.  **Buildspec:**
    * Select **Use a buildspec file**.
    * **Buildspec name:** `buildspec.json`.
6.  **Environment Variables:** Add the following. Note that all four credential variables now point to the same secret ARN.
    * `AWS_ACCOUNT_ID` | (Plaintext) | *Your 12-digit AWS Account ID*
    * `AWS_REGION` | (Plaintext) | `us-east-1`
    * `EKS_CLUSTER_NAME` | (Plaintext) | `myDemoEKS`
    * `IMAGE_REPO_NAME` | (Plaintext) | `my-secure-app`
    * `IMAGE_TAG` | (Plaintext) | `latest`
    * `PRISMA_CONSOLE_URL` | (Plaintext) | *Your full Prisma Console URL*
    * `PRISMA_USER` | (**Secrets Manager**) | *Full ARN of your `pipeline/credentials` secret, ending in `:PRISMA_USER`*
    * `PRISMA_PASS` | (**Secrets Manager**) | *Full ARN of your `pipeline/credentials` secret, ending in `:PRISMA_PASS`*
    * `DOCKERHUB_USER` | (**Secrets Manager**) | *Full ARN of your `pipeline/credentials` secret, ending in `:DOCKERHUB_USER`*
    * `DOCKERHUB_PASS` | (**Secrets Manager**) | *Full ARN of your `pipeline/credentials` secret, ending in `:DOCKERHUB_PASS`*
7.  Click **Create build project**.

---

## **Step 9: Run the Pipeline and Verify** ✅

1.  Navigate to your new CodeBuild project.
2.  Click **"Start build"**.
3.  The build should succeed.
4.  **To verify**, go to your **CloudShell** and run `kubectl get services`. Find the `my-secure-app-service` and copy its **EXTERNAL-IP** or **HOSTNAME** into your browser. You should see your secured application's webpage! 🎉

---

## **Step 10: Clean Up All Resources** 🧹

**Warning**: This step will permanently delete the resources you created to stop all AWS charges. Run these commands one by one in your **AWS CloudShell**.

1.  **Delete the EKS Cluster** (This is the most important step for cost savings and will take several minutes):
    ```bash
    eksctl delete cluster --name myDemoEKS --region us-east-1
    ```
2.  **Delete the CodeBuild Project**:
    ```bash
    aws codebuild delete-project --name prisma-github-defender-pipeline
    ```
3.  **Delete the ECR Repository**:
    ```bash
    aws ecr delete-repository --repository-name my-secure-app --region us-east-1 --force
    ```
4.  **Delete the IAM Role**:
    * First, detach the managed policies:
        ```bash
        aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
        aws iam detach-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
        ```
    * Next, delete the inline policies (replace the policy names if you named them differently):
        ```bash
        aws iam delete-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-name SecretsManagerAccessPolicy
        aws iam delete-role-policy --role-name CodeBuild-PublicRepo-EKS-Prisma-Role --policy-name EKSDescribeClusterPermission
        ```
    * Finally, delete the role itself:
        ```bash
        aws iam delete-role --role-name CodeBuild-PublicRepo-EKS-Prisma-Role
        ```
5.  **Delete the Secret** (**Important**: Replace the placeholder ARN with the actual ARN of your secret):
    ```bash
    aws secretsmanager delete-secret --secret-id ARN_FOR_PIPELINE_CREDENTIALS_SECRET_HERE --force-delete-without-recovery
    ```
After completing these commands, all resources for this lab will be removed.