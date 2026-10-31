"""build_species_info.match_names 的测试。"""

from build_species_info import match_names

IOC_BY_ZH = {
    "领鸺鹠": "Taenioptynx brodiei",
    "小苇鳽": "Botaurus minutus",
    "池鹭": "Ardeola bacchus",
}
TARGETS = {"Ardeola bacchus", "Taenioptynx brodiei", "Botaurus minutus", "Botaurus sinensis"}


def test_exact_scientific_name() -> None:
    """学名相同直接对上。"""
    assert match_names([("池鹭", "Ardeola bacchus")], TARGETS, IOC_BY_ZH) == {"Ardeola bacchus": "池鹭"}


def test_old_genus_found_through_ioc_chinese_name() -> None:
    """名录用旧学名时，借 IOC 的中文名找到新学名。"""
    names = match_names([("领鸺鹠", "Glaucidium brodiei")], TARGETS, IOC_BY_ZH)
    assert names == {"Taenioptynx brodiei": "领鸺鹠"}


def test_renamed_genus_applies_to_other_species() -> None:
    """经 IOC 中文名发现的属名变更（Ixobrychus → Botaurus）套用到 IOC 中文名对不上的同属种。"""
    china = [("小苇鳽", "Ixobrychus minutus"), ("黄斑苇鳽", "Ixobrychus sinensis")]
    names = match_names(china, TARGETS, IOC_BY_ZH)
    assert names == {"Botaurus minutus": "小苇鳽", "Botaurus sinensis": "黄斑苇鳽"}


def test_split_species_without_a_model_class_stays_unmatched() -> None:
    """中国名录单独拆出、模型里没有的种不硬配。"""
    assert match_names([("青藏楔尾伯劳", "Lanius giganteus")], TARGETS, IOC_BY_ZH) == {}
