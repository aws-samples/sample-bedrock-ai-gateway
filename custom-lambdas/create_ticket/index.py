"""
MCP Tool: Create incident ticket (mock ServiceNow).
Returns a mock ticket object simulating ServiceNow ticket creation.
In production, replace with actual ServiceNow API integration.
"""
import json
from datetime import datetime, timezone


def handler(event, context):
    """Lambda handler for create_ticket MCP tool."""
    try:
        # Extract arguments from MCP tool invocation
        if isinstance(event.get('arguments'), dict):
            args = event['arguments']
        elif isinstance(event.get('body'), str):
            args = json.loads(event['body'])
        else:
            args = event

        title = args.get('title', '')
        priority = args.get('priority', '')
        description = args.get('description', '')

        # Validate required fields
        if not title:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Missing required parameter: title'})
            }

        if not priority:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Missing required parameter: priority'})
            }

        valid_priorities = ['P1', 'P2', 'P3', 'P4']
        if priority not in valid_priorities:
            return {
                'statusCode': 400,
                'body': json.dumps({
                    'error': f'Invalid priority: {priority}. Must be one of: {valid_priorities}'
                })
            }

        # Generate mock ticket response
        now = datetime.now(timezone.utc)
        ticket_id = f"INC{now.strftime('%Y%m%d%H%M')}"

        ticket = {
            'ticket_id': ticket_id,
            'title': title,
            'priority': priority,
            'description': description,
            'status': 'created',
            'assigned_to': 'IT-Operations-Queue',
            'created_at': now.isoformat(),
            'updated_at': now.isoformat(),
            'category': 'Incident',
            'subcategory': 'General',
            'impact': '3 - Low' if priority in ['P3', 'P4'] else '2 - Medium' if priority == 'P2' else '1 - High',
            'urgency': '3 - Low' if priority == 'P4' else '2 - Medium' if priority == 'P3' else '1 - High'
        }

        return ticket

    except Exception as e:
        print(f"Error in create_ticket: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': f'Ticket creation failed: {str(e)}'})
        }
