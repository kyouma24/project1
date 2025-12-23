import boto3
import os
import datetime
import concurrent.futures
from botocore.exceptions import ClientError

# CONFIGURATION
SES_REGION = os.environ.get('SES_REGION', 'ap-southeast-1')
SENDER = os.environ.get('SENDER_EMAIL')
RECIPIENT = os.environ.get('RECIPIENT_EMAIL')
DAYS_THRESHOLD_SNAPSHOTS = 30
DAYS_THRESHOLD_STOPPED_EC2 = 7

# COST ESTIMATES (Average USD/Month for rough calculation)
COST_EBS_GB = 0.08       # Avg GP3 price
COST_SNAPSHOT_GB = 0.05  # Standard snapshot
COST_EIP = 3.65          # $0.005/hr * 730 hours
COST_ALB = 16.42         # ~$0.0225/hr * 730 hours

# Initialize Global Clients
ses = boto3.client('ses', region_name=SES_REGION)

def get_days_since(time_val):
    now = datetime.datetime.now(datetime.timezone.utc)
    if time_val.tzinfo is None:
        time_val = time_val.replace(tzinfo=datetime.timezone.utc)
    return (now - time_val).days

def get_tag_value(tags, key='Name'):
    """Extracts a specific tag value (default: Name) from a tag list."""
    if not tags: return "-"
    for tag in tags:
        if tag['Key'] == key:
            return tag['Value']
    return "-"

def get_enabled_regions():
    """Returns a list of all enabled regions."""
    ec2 = boto3.client('ec2', region_name='us-east-1')
    try:
        regions = [region['RegionName'] for region in ec2.describe_regions()['Regions']]
        return regions
    except ClientError:
        # Fallback if describe_regions fails (e.g. SCP restrictions)
        return ['us-east-1', 'ap-south-1', 'eu-west-1']

def scan_region(region):
    """Scans a single region for all waste types. Returns a list of findings."""
    # print(f"Scanning {region}...") # Commented out to reduce log noise in threading
    
    ec2 = boto3.client('ec2', region_name=region)
    elbv2 = boto3.client('elbv2', region_name=region)
    findings = []
    
    try:
        # 1. UNATTACHED EBS VOLUMES
        volumes = ec2.describe_volumes(Filters=[{'Name': 'status', 'Values': ['available']}])
        for vol in volumes['Volumes']:
            size = vol['Size']
            cost = size * COST_EBS_GB
            findings.append({
                'type': 'Unattached EBS',
                'region': region,
                'id': vol['VolumeId'],
                'name': get_tag_value(vol.get('Tags', [])),
                'details': f"{size} GB",
                'cost': cost
            })

        # 2. UNASSOCIATED EIPS
        addresses = ec2.describe_addresses()
        for eip in addresses['Addresses']:
            if 'AssociationId' not in eip:
                findings.append({
                    'type': 'Unused EIP',
                    'region': region,
                    'id': eip['PublicIp'],
                    'name': get_tag_value(eip.get('Tags', [])),
                    'details': "Idle Static IP",
                    'cost': COST_EIP
                })

        # 3. STOPPED EC2 INSTANCES (Zombies)
        # We check stopped instances because you still pay for their attached EBS
        instances = ec2.describe_instances(Filters=[{'Name': 'instance-state-name', 'Values': ['stopped']}])
        for r in instances['Reservations']:
            for inst in r['Instances']:
                stop_time = inst.get('StateTransitionReason', '')
                # Extract date from transition reason if possible, else use LaunchTime as proxy
                # This is a simplification; for exact stop time, CloudWatch is needed, but this works for "Old"
                days_stopped = "Unknown"
                if 'User initiated' in stop_time:
                     # A heuristic check, real production code might use CloudWatch metrics for exact "Days Idle"
                     pass 
                
                # Calculate cost of attached volumes
                storage_cost = 0
                for block in inst.get('BlockDeviceMappings', []):
                    if 'Ebs' in block:
                        # We would need to describe volume to get size, skipping for speed in this demo
                        # Assuming 30GB avg for estimation
                        storage_cost += (30 * COST_EBS_GB)

                findings.append({
                    'type': 'Stopped EC2',
                    'region': region,
                    'id': inst['InstanceId'],
                    'name': get_tag_value(inst.get('Tags', [])),
                    'details': "Stopped (Paying for EBS)",
                    'cost': storage_cost
                })

        # 4. IDLE LOAD BALANCERS
        lbs = elbv2.describe_load_balancers()
        for lb in lbs['LoadBalancers']:
            lb_arn = lb['LoadBalancerArn']
            tgs = elbv2.describe_target_groups(LoadBalancerArn=lb_arn)
            has_healthy = False
            for tg in tgs['TargetGroups']:
                health = elbv2.describe_target_health(TargetGroupArn=tg['TargetGroupArn'])
                for target in health['TargetHealthDescriptions']:
                    if target['TargetHealth']['State'] in ['healthy', 'initial']:
                        has_healthy = True
                        break
            if not has_healthy:
                findings.append({
                    'type': 'Idle Load Balancer',
                    'region': region,
                    'id': lb['LoadBalancerName'],
                    'name': "-", # ELBs don't always have simple Name tags in describe output
                    'details': "No Healthy Targets",
                    'cost': COST_ALB
                })

        # 5. OLD SNAPSHOTS
        account_id = boto3.client('sts').get_caller_identity().get('Account')
        snapshots = ec2.describe_snapshots(OwnerIds=[account_id])
        # (Optimization: Fetch Images only once per region is better, but keeping logic self-contained)
        images = ec2.describe_images(Owners=[account_id])
        active_amis = set()
        for img in images['Images']:
            for block in img.get('BlockDeviceMappings', []):
                if 'Ebs' in block and 'SnapshotId' in block['Ebs']:
                    active_amis.add(block['Ebs']['SnapshotId'])
        
        for snap in snapshots['Snapshots']:
            if snap['SnapshotId'] not in active_amis:
                days_old = get_days_since(snap['StartTime'])
                if days_old > DAYS_THRESHOLD_SNAPSHOTS:
                    size = snap['VolumeSize']
                    findings.append({
                        'type': 'Orphan Snapshot',
                        'region': region,
                        'id': snap['SnapshotId'],
                        'name': get_tag_value(snap.get('Tags', [])),
                        'details': f"{size} GB (> {days_old} days)",
                        'cost': size * COST_SNAPSHOT_GB
                    })

    except Exception as e:
        print(f"Error scanning {region}: {e}")
    
    return findings

def generate_html_report(all_findings):
    total_cost = sum(f['cost'] for f in all_findings)
    date_str = datetime.datetime.now().strftime("%Y-%m-%d")
    
    # Sort findings by cost (High to Low)
    sorted_findings = sorted(all_findings, key=lambda x: x['cost'], reverse=True)
    
    rows = ""
    for f in sorted_findings:
        rows += f"""
        <tr style="border-bottom: 1px solid #eee;">
            <td style="padding: 10px; color: #555;">{f['type']}</td>
            <td style="padding: 10px; font-weight: bold;">{f['region']}</td>
            <td style="padding: 10px;">{f['id']}<br><span style="font-size:11px; color:#888;">{f['name']}</span></td>
            <td style="padding: 10px;">{f['details']}</td>
            <td style="padding: 10px; color: #d9534f; font-weight: bold;">${f['cost']:.2f}</td>
        </tr>
        """

    html = f"""
    <html>
    <body style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f4f4; padding: 20px;">
        <div style="max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); overflow: hidden;">
            <div style="background-color: #232f3e; color: white; padding: 25px; text-align: center;">
                <h2 style="margin: 0;">AWS Waste Report</h2>
                <p style="margin: 5px 0 0; opacity: 0.8;">Generated: {date_str}</p>
            </div>
            
            <div style="padding: 20px; background-color: #fff3cd; color: #856404; text-align: center; font-weight: bold; border-bottom: 1px solid #faebcc;">
                💰 POTENTIAL MONTHLY SAVINGS: ${total_cost:.2f}
            </div>
            
            <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
                <thead style="background-color: #f8f9fa; color: #333;">
                    <tr>
                        <th style="padding: 12px; text-align: left;">Type</th>
                        <th style="padding: 12px; text-align: left;">Region</th>
                        <th style="padding: 12px; text-align: left;">Resource / Name</th>
                        <th style="padding: 12px; text-align: left;">Details</th>
                        <th style="padding: 12px; text-align: left;">Est. Save/Mo</th>
                    </tr>
                </thead>
                <tbody>
                    {rows}
                </tbody>
            </table>
            
            <div style="padding: 20px; text-align: center; color: #777; font-size: 12px; border-top: 1px solid #eee;">
                <p>Estimates are based on average GP3/standard pricing. Actual savings may vary based on savings plans or specific volume types.</p>
            </div>
        </div>
    </body>
    </html>
    """
    return html, total_cost

def lambda_handler(event, context):
    print("--- Starting Parallel FinOps Scan ---")
    regions = get_enabled_regions()
    print(f"Targeting {len(regions)} regions.")
    
    all_findings = []
    
    # PARALLEL EXECUTION
    # Using ThreadPoolExecutor to run scan_region for multiple regions at once
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        # Submit all tasks
        future_to_region = {executor.submit(scan_region, r): r for r in regions}
        
        for future in concurrent.futures.as_completed(future_to_region):
            region = future_to_region[future]
            try:
                data = future.result()
                all_findings.extend(data)
            except Exception as exc:
                print(f"{region} generated an exception: {exc}")

    if all_findings:
        html_report, total_waste_cost = generate_html_report(all_findings)
        print(f"Total Waste Found: ${total_waste_cost:.2f}")
        
        try:
            ses.send_email(
                Source=SENDER,
                Destination={'ToAddresses': [RECIPIENT]},
                Message={
                    'Subject': {
                        'Data': f"💸 AWS Waste Report: ${total_waste_cost:.2f} Potential Savings",
                        'Charset': 'UTF-8'
                    },
                    'Body': {'Html': {'Data': html_report, 'Charset': 'UTF-8'}}
                }
            )
            return {"status": "Report Sent", "savings": total_waste_cost}
        except Exception as e:
            print(f"SES Error: {e}")
            raise e
    else:
        print("Clean environment! No email sent.")
        return {"status": "Clean"}