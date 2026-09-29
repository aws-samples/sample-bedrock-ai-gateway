import os
import boto3


def handler(event, context):
    """Search Bedrock Knowledge Base and return relevant document excerpts."""
    try:
        kb_id = os.environ["KNOWLEDGE_BASE_ID"]
        query = event.get("arguments", {}).get("query", "")

        if not query:
            return {"results": [], "count": 0}

        client = boto3.client("bedrock-agent-runtime")

        response = client.retrieve(
            knowledgeBaseId=kb_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "vectorSearchConfiguration": {"numberOfResults": 5}
            },
        )

        results = []
        for item in response.get("retrievalResults", []):
            text = item.get("content", {}).get("text", "")
            score = item.get("score", 0)
            source = (
                item.get("location", {}).get("s3Location", {}).get("uri", "unknown")
            )

            results.append(
                {"text": text[:500], "score": str(score), "source": source}
            )

        return {"results": results, "count": len(results)}

    except Exception as e:
        return {"error": str(e), "results": [], "count": 0}
