import requests
import json


def main():
    url = "http://localhost:4000"

    # Example echo method
    payload = {
        "method": "echo",
        "params": ["echome!"],
        "jsonrpc": "2.0",
        "id": 0,
    }
    response = requests.post(url, json=payload).json()

    assert response["result"] == "echome!"
    assert response["jsonrpc"]
    assert response["id"] == "0"

    print("ok")

if __name__ == "__main__":
    main()