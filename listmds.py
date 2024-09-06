import os, natsort

def recursive_list_md_files(directory: str, starts_with: str = "") -> list:
    files = []
    for root, _, filenames in os.walk(directory):
        for filename in filenames:
            if filename.endswith(".md"):
                if starts_with == "" or filename.startswith(starts_with):
                    files.append(os.path.join(root, filename))
    return natsort.natsorted(files)



print(recursive_list_md_files("hack_console/challenges", "challenge"))
print(recursive_list_md_files("hack_console/solutions", "solution"))