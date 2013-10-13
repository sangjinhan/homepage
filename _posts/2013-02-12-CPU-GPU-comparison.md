---
layout: post
section: blog
title: "On Fair Comparison between CPU and GPU"
---

# {{page.title}}

As a <s>noob</s> newbie Computer Science researcher, it is always fun and 
rewarding to watch people discussing about our research papers somewhere 
on the Internet. Besides some obvious implications (e.g., fresh perspectives 
from practitioners on the research subjects), it is a strong indicator that 
my paper was not completely irrelevant junk that get published but nobody 
really cares about it. Today, I came across a tweet thread about our
[SSLShader](http://www.eecs.berkeley.edu/~sangjin/static/pub/nsdi2011_sslshader.pdf)
work, or more specifically, about the RSA implementation on GPUs, which is 
what I was responsible for, as a second author of the paper.
Soon I found a somewhat depressing tweet about the paper.

> "\[...\] the benchmark methodology is flawed. Single threaded CPU comparison only."

Ugh... "flawed". Really? I know I should not take this personal, but my heart 
is broken. If I read this tweet at night I would have completely lost my sleep. 
The most problematic(?) parts of the paper are as follows, but please read the 
full paper if interested:

<p style="text-align: center">
<img src='static/blog_images/2013-02-12-fig.png' alt='Figure4' style="width: 100%"> 
</p>

<p style="text-align: center">
<img src='static/blog_images/2013-02-12-table.png' alt='Table1' /> 
</p>

<p style="text-align: center">
<img src='static/blog_images/2013-02-12-text.png' alt='Text' />
</p>

The figure, table, and text compare the RSA performance between the GPU
(ours) and CPU (from Intel IPP) implementations.
The CPU numbers are from a single CPU core. Do not throw stones yet.

To be fair, I think the negative reaction is pretty much reasonable
<s>(after having a 2-hour meditation)</s>. There are 
a bunch of academic papers that make clearly unfair comparisons between the 
CPU and GPU implementations, in order for their GPU implementations to look 
shinier than actually are. If my published paper was not clear enough to avoid 
those kinds of misunderstanding, it is primarily my fault.
But let me defend our paper a little bit, by explaining some 
contexts on how to make a _fair comparison_ in general and how it applied to
our work.

## How to Make Fair Comparisons

It is pretty much easy to find papers claiming that 
"our GPU implementation shows an orders of magnitude speedup over CPU". 
But they often make a comparison 
between _a highly optimized GPU implementation_ and _an unoptimized,
single-core CPU implementation_. Perhaps one can simply see our paper as 
one of them. But trust me. It is not what it seems like.

Actually I am a huge fan of the ISCA 2010 paper,
["Debunking the 100X GPU vs. CPU Myth"](http://pcl.intel-research.net/publications/isca319-lee.pdf), 
and it was indeed a kind of guideline for our work to not repeat common 
mistakes. Some quick takeaways from the paper are:

* 100-1000x speedups are illusions. The authors found that the gap between
  a single GPU and a single multi-core CPU narrows
  down to 2.5x on average, after applying extensive optimization 
  for both CPU and GPU implementations.

* The expected speedup is highly variable depending on workloads.

* For optimal performance, an implementation must fully exploit opportunities
  provided by the underlying hardware. Many research papers tend to do this 
  for their GPU implementations, but not much for the CPU implementations.
  
In summary, for a fair comparison between GPU and CPU performance for a 
specific application, you must ensure to optimize your CPU implementation
to the reasonably acceptable level. You should parallelize your algorithm
to run across multiple CPU cores. The memory access should be cache-friendly
as much as possible. Your code should not confuse the branch predictor.
SIMD operations, such as SSE, are crucial to exploit the instruction-level
parallelism. 

(In my personal opinion, CPU code optimization seems to take significantly 
 more efforts than GPU code optimization at least for embarrassingly parallel 
 algorithms, but anyways, not very relevant for this article.)

Of course there are some obvious, critical mistakes made by many 
papers, not addressed in detail in the above paper. Let me call these
_three deadly sins_.

* Sometimes not all parts of algorithms are completely offloadable to the GPU,
  leaving some non-parallelizable tasks for the CPU. Some papers only report
  the GPU kernel time, even if the CPU runtime cannot be completely hidden 
  with overlapping, due to dependency.

* More often, many papers assume that the input data is already on the GPU
  memory, and do not copy the output data back to the host memory.
  In reality, data transfer between host and GPU memory takes significant
  time, often more than the kernel run time itself depending on the 
  computational intensity of the algorithm.

* Often it is assumed that you always have large data for enough parallelism
  for full utilization of GPU. In some _online_ applications, 
  such as network applications as in our paper, it is not always true.

While it is not directly related to GPU, the paper
["Twelve ways to fool the masses when giving performance results on parallel computers"](http://crd-legacy.lbl.gov/~dhbailey/dhbpapers/twelve-ways.pdf)
provides another interesting food for thought, in the general context of 
parallel computing.

## What We Did for a Fair Comparison

Defense time.

### Was our CPU counterpart was optimized enough?

We tried a dozen of publicly available RSA implementations to find the
fastest one, including our own implementation. 
[Intel IPP](http://software.intel.com/en-us/intel-ipp) 
(Integrated Performance Primitives) beat everything else, by a huge margin. 
It is heavily optimized with SSE intrinsics by Intel experts, and our platform 
was, not surprisingly, Intel. For instance, it ran up to three times faster
than the OpenSSL implementations, depending on their versions (no worries,
the latest OpenSSL versions runs much faster than it used to be).

### Why show the single-core performance?

The reason is threefold.

1. RSA is simply not parallelizable, at a coarse-grained scale for CPUs. 
   Simply put, one RSA operation with a 1k-bit key requires roughly 768 modular
   multiplications of large integers, and each multiplication is dependent on 
   the result of the previous multiplication. 
   The only thing we can do is to parallelize each multiplication 
   (and this is what we do in our work). 
   To my best knowledge, this is true not only for RSA, 
   but also for any public-key algorithms based on modular exponentiation.
   It would be a great research project, if one can derive a fully 
   parallelizable public-key algorithm that still provides comparable crypto 
   strength to RSA. Seriously.

2. The only coarse-grained parallelism found in RSA is from Chinese Remainder
   Theorem, which breaks an RSA operation into two independent modular
   exponentiations, thus runnable on two CPU cores. While this can reduce
   the latency of each RSA operation, note that it does not help the total
   throughput, since the total amount of work remains the same.
   Actually IPP supports for this mode, but it shows lower throughput than
   the single-core case, due to the communication cost between cores.
   Fine-grained parallelization of each modular multiplication on multiple CPU 
   cores is simply a disaster. Even too obvious to state.

3. For those reasons, it is best for the CPU evaluation to run the sequential
   algorithm on individual RSA messages, on each core. We compare the
   sequential, non-parallelizable CPU implementation performance with the parallelized GPU 
   implementation performance. This is why we show the single-core performance.
   One can make a rough estimation for her own environment from our single-core 
   throughput, by considering the number of cores she has and the clock 
   frequency.

In our paper, we clearly emphasized several times that the performance result 
is from __a single core__, not to be misunderstood as a whole CPU or a whole 
system (our server had two hexa-core Xeon processors).
We also state that how many CPU cores are needed to match the GPU performance.
And finally, perhaps most importantly, we make explicit chip-level comparisons, 
between a GPU, CPUs (as a whole), and a security processor in the Discussion
section.

### What about the three deadly sins above? 

We accounted all the CPU and GPU run time for the GPU results. They also
include memory transfer time between CPU and GPU and the kernel launch 
overheads.

Our paper does not simply say that RSA always runs faster on GPUs than CPUs.
Instead, it clearly explains when is better to offload RSA operations to
GPUs and when is not, and how to make a good decision dynamically, in terms of
throughput and latency. The main system, SSLShader, opportunistically
switch between CPU and GPU crypto operations as explained in the paper.

In short, __we did our best to make fair comparisons__.

## Time for Self-Criticism: My Faults in the Paper

Of course, I found that <s>myself</s> the paper was not completely free
from some of common mistakes. Admittedly, this is a painful, but constructive
aspect of what I can learn from seemingly harsh comments on my research.
Here comes the list:

* Perhaps the most critical mistake must be 
  "In our evaluation, the GPU implementation of RSA shows a factor of 22.6 
  to 31.7 improvement over the fastest CPU implementation". IN THE ABSTRACT.
  Yikes. It should have clearly stated that the CPU result was from
  the single-core case, as done in the main text.

* Our paper lacks the context described above: "why we showed the single-core
  CPU performance".

* The paper does not explicitly say about what would be the expected 
  throughput if we run the non-parallelizable algorithm on multiple CPU cores, 
  individually. Clearly (single-core performance) * (# of cores) is the upper 
  bound, since you cannot expect super-linear speedup for running on
  independent data. However, the speedup may be significantly lower than the
  number of cores, as commonly seen in multi-core applications.
  The answer was, _it shows almost perfect linear scalability_, since RSA
  operations have so small cache footprint that each core does not interfere
  with others. While the Table 4 implied it, the paper should have been explicit 
  about this.

* The graphs above. They should have had lines for multi-core cases, 
  [as we had done for another research project](http://www.eecs.berkeley.edu/~sangjin/static/pub/nsdi2010_packetshader.pdf).
  One small excuse: please blame conferences with page limits.
  In many Computer Science research areas, including mine, conferences are
  primary venues for publication. Not journals with no page limits.
