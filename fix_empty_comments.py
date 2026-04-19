import glob
import re

def clean_file(filepath):
    with open(filepath, 'r') as f:
        text = f.read()

    # Repeated blank comment lines in NatSpec blocks
    # Replace "\n *\n *" with "\n *"
    new_text = re.sub(r'(\n\s*\*\s*){2,}', '\n *\n', text)
    
    # If the block is just `/** \n * \n */` make it `/** \n */`
    new_text = re.sub(r'/\*\*\s*\n\s*\*\s*\n\s*\*/', '/**\n */', new_text)

    if new_text != text:
        with open(filepath, 'w') as f:
            f.write(new_text)

files = glob.glob('src/**/*.sol', recursive=True)
for f in files:
    clean_file(f)

