"""Public-domain books for the screenshot catalog (/opds/showcase): (title, author, series, number in it)."""

SHOWCASE = [
    ("Pride and Prejudice", "Jane Austen", None, None),
    ("Moby-Dick", "Herman Melville", None, None),
    ("Frankenstein", "Mary Shelley", None, None),
    ("The Time Machine", "H. G. Wells", None, None),
    ("Dracula", "Bram Stoker", None, None),
    ("Middlemarch", "George Eliot", None, None),
    ("A Study in Scarlet", "Arthur Conan Doyle", "Sherlock Holmes", 1),
    ("The Sign of the Four", "Arthur Conan Doyle", "Sherlock Holmes", 2),
    ("Jane Eyre", "Charlotte Brontë", None, None),
    ("The Count of Monte Cristo", "Alexandre Dumas", None, None),
    ("Little Women", "Louisa May Alcott", None, None),
    ("The War of the Worlds", "H. G. Wells", None, None),
]

# Background colour pairs (top, bottom) of the generated covers, one per book
PALETTE = [
    ((122, 40, 52), (58, 18, 30)),
    ((24, 64, 96), (10, 28, 48)),
    ((46, 70, 52), (18, 32, 24)),
    ((92, 76, 40), (44, 34, 16)),
    ((70, 20, 24), (24, 6, 10)),
    ((60, 80, 110), (28, 36, 60)),
    ((110, 64, 30), (52, 28, 12)),
    ((40, 40, 72), (16, 16, 36)),
    ((96, 56, 88), (44, 22, 40)),
    ((20, 84, 90), (8, 38, 44)),
    ((140, 96, 60), (70, 44, 24)),
    ((56, 56, 56), (20, 20, 20)),
]

# Genre facets of the OPDS 2.0 showcase (/opds2/showcase/books?genre=...): book numbers, from 1
GENRES = {
    "Science fiction": [3, 4, 12],
    "Gothic": [3, 5],
    "Mystery": [7, 8],
}

# Publication years, for the book details of the OPDS 2.0 showcase
YEARS = [1813, 1851, 1818, 1895, 1897, 1871, 1887, 1890, 1847, 1844, 1868, 1898]
