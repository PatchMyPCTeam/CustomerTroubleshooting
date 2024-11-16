# Procmon Filters for Customer Troubleshooting

This repository contains a collection of **Procmon (Process Monitor)** filters designed to assist with **customer troubleshooting**. These filters can be used to monitor and capture specific system activity, such as file access, registry activity, network traffic, and more, to diagnose issues reported by customers.

## Contents

The folder includes Procmon filter configurations for common troubleshooting scenarios.

## How to Use the Procmon Filters

### 1. Download and Install Procmon

You will need to have **Procmon** installed on your machine to use the filters:

- Download **Procmon** from the official **Microsoft Sysinternals** website:  
  [Procmon Download](https://docs.microsoft.com/en-us/sysinternals/downloads/procmon)

### 2. Importing Filters into Procmon

Once you have **Procmon** installed, follow these steps to import the provided filters:

1. **Open Procmon**: Launch Procmon as an administrator to capture system-wide activity.
2. **Load Filters**:
   - Go to **Filter** and select **Organize Filters**.
   - Click **Import** and browse to the appropriate `.pmf` filter file provided in this repository.
3. **Start Capturing**:
   - After importing the filter, click **OK** to apply the filter and start capturing data.
   - Let the capture run until you have gathered enough data, then stop the capture using the **File > Capture Events** option.

### 3. Analyzing Captured Data

- Visit the Patch My PC KB article on using **Procmon** to help diagnose publishing issues:  
  [How to use Process Monitor to help diagnose publishing issues](https://patchmypc.com/how-to-use-process-monitor-to-help-diagnose-publishing-issues)