"""Minimal axes-only version of the measured popularity comparison."""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager, ticker
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--results', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
rows = {row['model']: row for row in json.loads(args.results.read_text())['summary']}
font = Path(r'C:\Windows\Fonts\msyh.ttc')
if font.exists():
    font_manager.fontManager.addfont(str(font))
    plt.rcParams['font.family'] = font_manager.FontProperties(fname=str(font)).get_name()
plt.rcParams['svg.fonttype'] = 'none'
plt.rcParams['axes.unicode_minus'] = False

fig, axes = plt.subplots(1, 3, figsize=(16, 4), dpi=250)
fig.subplots_adjust(left=.15, right=.98, bottom=.23, top=.96, wspace=.34)
methods = ['PakPerk weighted', 'MostPop']
for index, (ax, metric, label, factor, limit, step) in enumerate(zip(
    axes, ['ndcg10', 'recall10', 'coverage'],
    ['nDCG@10', 'Recall@10（%）', '目录覆盖率（%）'],
    [1, 100, 100], [.65, 65, 44], [.2, 20, 10],
)):
    values = [rows[m][metric]['mean'] if isinstance(rows[m][metric], dict)
              else rows[m][metric] for m in methods]
    values = np.array(values) * factor
    ax.barh([0, 1], values, color=['#27604C', '#A3B0AA'], height=.42)
    if metric != 'coverage':
        errors = np.array([[rows[m][metric]['mean']-rows[m][metric]['lo'] for m in methods],
                           [rows[m][metric]['hi']-rows[m][metric]['mean'] for m in methods]]) * factor
        ax.errorbar(values, [0, 1], xerr=errors, fmt='none',
                    ecolor='#293E36', capsize=3, lw=1)
    for y, value in enumerate(values):
        text = f'{value:.3f}' if metric == 'ndcg10' else f'{value:.1f}'
        ax.text(value+limit*.035, y, text, va='center', fontsize=16, color='#22392E')
    ax.set_yticks([0, 1], ['PakPerk 默认策略', '热门推荐'] if index == 0 else ['', ''])
    if index == 0:
        ax.set_ylabel('推荐方法', fontsize=16, labelpad=16, color='#22392E')
    ax.set_xlabel(label, fontsize=17, labelpad=16, color='#22392E')
    ax.set_xlim(0, limit); ax.set_ylim(1.55, -.55)
    ax.xaxis.set_major_locator(ticker.MultipleLocator(step))
    ax.tick_params(length=0, labelsize=15, pad=9, colors='#344E43')
    ax.xaxis.grid(True, color='#DDE4DF', lw=.7)
    ax.set_axisbelow(True); ax.set_facecolor('none')
    for spine in ax.spines.values():
        spine.set_visible(False)

fig.savefig(args.output/'strengths-simple-transparent.png', transparent=True, dpi=250)
fig.savefig(args.output/'strengths-simple.png', facecolor='white', dpi=250)
fig.savefig(args.output/'strengths-simple.svg', transparent=True)
plt.close(fig)
