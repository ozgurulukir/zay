from __future__ import annotations

import argparse
from pathlib import Path

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export the bash classifier to ONNX.")
    parser.add_argument("--model-dir", default="ModernBERT-bash-classifier")
    parser.add_argument("--output", default="ModernBERT-bash-classifier/model.onnx")
    parser.add_argument("--max-length", type=int, default=512)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    model_dir = Path(args.model_dir)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(model_dir)
    model = AutoModelForSequenceClassification.from_pretrained(model_dir)
    model.eval()
    tokenizer.save_pretrained(output.parent)
    model.config.save_pretrained(output.parent)

    encoded = tokenizer(
        "printf hello",
        return_tensors="pt",
        truncation=True,
        max_length=args.max_length,
    )
    input_names = list(encoded.keys())
    dynamic_axes = {name: {0: "batch", 1: "sequence"} for name in input_names}
    dynamic_axes["logits"] = {0: "batch"}

    with torch.no_grad():
        torch.onnx.export(
            model,
            tuple(encoded[name] for name in input_names),
            output,
            input_names=input_names,
            output_names=["logits"],
            dynamic_axes=dynamic_axes,
            opset_version=18
        )


if __name__ == "__main__":
    main()
